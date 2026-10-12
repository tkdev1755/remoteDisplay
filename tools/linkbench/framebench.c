/*
 * framebench — measures what a point-to-point link can do for remoteDisplay-like
 * traffic: whole frames cut into large UDP datagrams, sent in one burst per frame.
 *
 *   receiver (iMac):  ./framebench recv [--port 6000]
 *   sender   (Mac):   ./framebench send <ip> [--port 6000] [--frame-bytes N]
 *                     [--fps F | --fps 0 for back-to-back] [--seconds S]
 *                     [--chunk 65000] [--sndbuf BYTES] [--label NAME]
 *
 * The receiver acknowledges every complete frame with a tiny datagram. The sender
 * measures, on its own clock only (no clock sync needed):
 *   - delivery: frames acknowledged / frames sent;
 *   - latency:  start of the frame's burst -> its acknowledgement arrives back;
 *   - goodput:  bytes of acknowledged frames per second.
 * The acknowledgement also carries the receiver-side burst duration
 * (first chunk -> last chunk received), measured on the receiver's clock.
 *
 * Builds on macOS (clang) and Linux (gcc):  cc -O2 -o framebench framebench.c -lm
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAGIC_DATA 0x52444231u /* "RDB1" */
#define MAGIC_ACK  0x52444241u /* "RDBA" */
#define SLOTS 1024
#define MAX_CHUNK 65400

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;
    uint32_t run_id;
    uint32_t frame_id;
    uint16_t chunk_id;
    uint16_t total_chunks;
} DataHeader;

typedef struct {
    uint32_t magic;
    uint32_t run_id;
    uint32_t frame_id;
    uint32_t chunks;
    uint64_t burst_ns; /* receiver clock: first chunk -> last chunk */
} Ack;
#pragma pack(pop)

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void sleep_until(uint64_t deadline)
{
    for (;;) {
        uint64_t t = now_ns();
        if (t >= deadline)
            return;
        uint64_t left = deadline - t;
        struct timespec ts = { (time_t)(left / 1000000000ull), (long)(left % 1000000000ull) };
        nanosleep(&ts, NULL);
    }
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static double pct_ms(uint64_t *v, size_t n, double p)
{
    if (n == 0)
        return NAN;
    size_t i = (size_t)ceil(p / 100.0 * (double)n);
    if (i == 0)
        i = 1;
    if (i > n)
        i = n;
    return (double)v[i - 1] / 1e6;
}

static int set_buf(int fd, int opt, int want)
{
    /* Try the requested size, then halve until the kernel accepts it. */
    for (int size = want; size >= 65536; size /= 2)
        if (setsockopt(fd, SOL_SOCKET, opt, &size, sizeof size) == 0)
            break;
    int got = 0;
    socklen_t len = sizeof got;
    getsockopt(fd, SOL_SOCKET, opt, &got, &len);
    return got;
}

/* ------------------------------------------------------------------ receiver */

typedef struct {
    uint32_t run_id, frame_id;
    uint32_t chunks, total;
    uint64_t first_ns, last_ns;
    int done;
} Slot;

static int run_receiver(int port)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_RCVBUFFORCE
    int force = 64 * 1024 * 1024;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &force, sizeof force) != 0)
#endif
        set_buf(fd, SO_RCVBUF, 64 * 1024 * 1024);
    int rcvbuf = 0;
    socklen_t len = sizeof rcvbuf;
    getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, &len);

    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port),
                                .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) { perror("bind"); return 1; }
    fprintf(stderr, "framebench recv: listening on UDP :%d (SO_RCVBUF = %d bytes). Ctrl-C to stop.\n",
            port, rcvbuf);

    static Slot slots[SLOTS];
    static uint8_t buf[MAX_CHUNK + 64];
    uint32_t current_run = 0;
    uint64_t frames_done = 0;

    for (;;) {
        struct sockaddr_in from;
        socklen_t flen = sizeof from;
        ssize_t n = recvfrom(fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &flen);
        uint64_t t = now_ns();
        if (n < (ssize_t)sizeof(DataHeader))
            continue;
        DataHeader h;
        memcpy(&h, buf, sizeof h);
        if (h.magic != MAGIC_DATA || h.total_chunks == 0)
            continue;
        if (h.run_id != current_run) {
            if (current_run != 0)
                fprintf(stderr, "run %u finished: %llu complete frames\n", current_run,
                        (unsigned long long)frames_done);
            current_run = h.run_id;
            frames_done = 0;
            memset(slots, 0, sizeof slots);
        }
        Slot *s = &slots[h.frame_id % SLOTS];
        if (s->run_id != h.run_id || s->frame_id != h.frame_id) {
            s->run_id = h.run_id;
            s->frame_id = h.frame_id;
            s->chunks = 0;
            s->total = h.total_chunks;
            s->first_ns = t;
            s->done = 0;
        }
        if (s->done)
            continue;
        s->chunks++;
        s->last_ns = t;
        if (s->chunks == s->total) {
            s->done = 1;
            frames_done++;
            Ack a = { MAGIC_ACK, h.run_id, h.frame_id, s->chunks, s->last_ns - s->first_ns };
            sendto(fd, &a, sizeof a, 0, (struct sockaddr *)&from, flen);
        }
    }
}

/* -------------------------------------------------------------------- sender */

static void drain_acks(int fd, uint32_t run_id, const uint64_t *t0, uint64_t *lat, uint64_t *burst,
                       uint8_t *acked, size_t frames_cap, size_t *n_acks, int timeout_ms)
{
    struct pollfd p = { .fd = fd, .events = POLLIN };
    while (poll(&p, 1, timeout_ms) > 0) {
        Ack a;
        ssize_t n = recv(fd, &a, sizeof a, 0);
        uint64_t t = now_ns();
        if (n == (ssize_t)sizeof a && a.magic == MAGIC_ACK && a.run_id == run_id &&
            a.frame_id < frames_cap && !acked[a.frame_id]) {
            acked[a.frame_id] = 1;
            lat[*n_acks] = t - t0[a.frame_id];
            burst[*n_acks] = a.burst_ns;
            (*n_acks)++;
        }
        timeout_ms = 0; /* after the first wait, only take what is already there */
    }
}

static int run_sender(const char *ip, int port, size_t frame_bytes, double fps, double seconds,
                      size_t chunk, int sndbuf, const char *label)
{
    if (chunk + sizeof(DataHeader) > MAX_CHUNK) {
        fprintf(stderr, "chunk too large (max %zu)\n", (size_t)MAX_CHUNK - sizeof(DataHeader));
        return 1;
    }
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket"); return 1; }
    int got_sndbuf = set_buf(fd, SO_SNDBUF, sndbuf);
    set_buf(fd, SO_RCVBUF, 4 * 1024 * 1024);
    struct sockaddr_in dst = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) { fprintf(stderr, "bad ip %s\n", ip); return 1; }
    if (connect(fd, (struct sockaddr *)&dst, sizeof dst) != 0) { perror("connect"); return 1; }

    size_t total_chunks = (frame_bytes + chunk - 1) / chunk;
    if (total_chunks > 65535) { fprintf(stderr, "too many chunks per frame\n"); return 1; }
    double planned = fps > 0 ? fps * seconds : 1e6;
    size_t frames_cap = (size_t)planned + 16;
    uint64_t *t0 = calloc(frames_cap, sizeof *t0);
    uint64_t *lat = calloc(frames_cap, sizeof *lat);
    uint64_t *burst = calloc(frames_cap, sizeof *burst);
    uint8_t *acked = calloc(frames_cap, 1);
    uint8_t *pkt = calloc(1, chunk + sizeof(DataHeader));
    if (!t0 || !lat || !burst || !acked || !pkt) { fprintf(stderr, "out of memory\n"); return 1; }
    memset(pkt + sizeof(DataHeader), 0xA5, chunk);

    uint32_t run_id = (uint32_t)(now_ns() & 0x7fffffff) | 1u;
    uint64_t period = fps > 0 ? (uint64_t)(1e9 / fps) : 0;
    uint64_t start = now_ns(), end = start + (uint64_t)(seconds * 1e9);
    uint64_t next = start;
    size_t frames = 0, n_acks = 0;
    uint64_t send_errors = 0, enobufs = 0, bytes_sent = 0;

    while (frames < frames_cap && now_ns() < end) {
        if (period)
            sleep_until(next);
        uint64_t f0 = now_ns();
        t0[frames] = f0;
        for (size_t c = 0; c < total_chunks; c++) {
            size_t len = (c == total_chunks - 1) ? frame_bytes - c * chunk : chunk;
            DataHeader h = { MAGIC_DATA, run_id, (uint32_t)frames, (uint16_t)c, (uint16_t)total_chunks };
            memcpy(pkt, &h, sizeof h);
            for (;;) {
                ssize_t n = send(fd, pkt, sizeof h + len, 0);
                if (n >= 0) { bytes_sent += (uint64_t)n; break; }
                if (errno == ENOBUFS || errno == EAGAIN) { enobufs++; continue; } /* kernel queue full: retry */
                send_errors++;
                if (errno == EMSGSIZE) {
                    fprintf(stderr, "EMSGSIZE: datagram of %zu bytes refused. On macOS: "
                            "sudo sysctl -w net.inet.udp.maxdgram=65535\n", sizeof h + len);
                    return 1;
                }
                break;
            }
        }
        frames++;
        if (period) {
            next += period;
            int wait_ms = (int)((next > now_ns() ? next - now_ns() : 0) / 1000000);
            drain_acks(fd, run_id, t0, lat, burst, acked, frames_cap, &n_acks, wait_ms > 1 ? wait_ms - 1 : 0);
        } else {
            drain_acks(fd, run_id, t0, lat, burst, acked, frames_cap, &n_acks, 0);
        }
    }
    uint64_t send_end = now_ns();
    drain_acks(fd, run_id, t0, lat, burst, acked, frames_cap, &n_acks, 500);
    while (n_acks < frames) { /* late stragglers */
        size_t before = n_acks;
        drain_acks(fd, run_id, t0, lat, burst, acked, frames_cap, &n_acks, 200);
        if (n_acks == before)
            break;
    }

    double elapsed = (double)(send_end - start) / 1e9;
    double offered_gbps = (double)bytes_sent * 8 / elapsed / 1e9;
    double goodput_gbps = (double)n_acks * (double)frame_bytes * 8 / elapsed / 1e9;
    qsort(lat, n_acks, sizeof *lat, cmp_u64);
    qsort(burst, n_acks, sizeof *burst, cmp_u64);
    double delivered = frames ? 100.0 * (double)n_acks / (double)frames : 0;

    printf("label=%s frame_bytes=%zu chunk=%zu chunks_per_frame=%zu fps_target=%.0f seconds=%.1f "
           "sndbuf=%d frames_sent=%zu frames_acked=%zu delivered_pct=%.2f achieved_fps=%.1f "
           "offered_gbps=%.2f goodput_gbps=%.2f "
           "lat_p50_ms=%.2f lat_p95_ms=%.2f lat_p99_ms=%.2f lat_max_ms=%.2f "
           "burst_p50_ms=%.2f burst_p95_ms=%.2f burst_max_ms=%.2f enobufs_retries=%llu send_errors=%llu\n",
           label, frame_bytes, chunk, total_chunks, fps, seconds, got_sndbuf, frames, n_acks, delivered,
           (double)frames / elapsed, offered_gbps, goodput_gbps,
           pct_ms(lat, n_acks, 50), pct_ms(lat, n_acks, 95), pct_ms(lat, n_acks, 99),
           n_acks ? (double)lat[n_acks - 1] / 1e6 : NAN,
           pct_ms(burst, n_acks, 50), pct_ms(burst, n_acks, 95),
           n_acks ? (double)burst[n_acks - 1] / 1e6 : NAN,
           (unsigned long long)enobufs, (unsigned long long)send_errors);
    return 0;
}

/* ---------------------------------------------------------------------- main */

static void usage(void)
{
    fprintf(stderr,
            "usage:\n"
            "  framebench recv [--port P]\n"
            "  framebench send <ip> [--port P] [--frame-bytes N] [--fps F] [--seconds S]\n"
            "                       [--chunk N] [--sndbuf N] [--label NAME]\n"
            "  --fps 0 sends frames back-to-back (maximum rate).\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(); return 1; }
    int port = 6000;
    size_t frame_bytes = 4096u * 2304u * 3u / 2u; /* 4096x2304 NV12 */
    double fps = 60, seconds = 10;
    size_t chunk = 65000;
    int sndbuf = 8 * 1024 * 1024;
    const char *label = "run";
    const char *ip = NULL;
    int i = 2;
    if (strcmp(argv[1], "send") == 0) {
        if (argc < 3) { usage(); return 1; }
        ip = argv[2];
        i = 3;
    } else if (strcmp(argv[1], "recv") != 0) {
        usage();
        return 1;
    }
    for (; i < argc; i += 2) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!v) { usage(); return 1; }
        if (!strcmp(a, "--port")) port = atoi(v);
        else if (!strcmp(a, "--frame-bytes")) frame_bytes = (size_t)strtoull(v, NULL, 10);
        else if (!strcmp(a, "--fps")) fps = atof(v);
        else if (!strcmp(a, "--seconds")) seconds = atof(v);
        else if (!strcmp(a, "--chunk")) chunk = (size_t)strtoull(v, NULL, 10);
        else if (!strcmp(a, "--sndbuf")) sndbuf = atoi(v);
        else if (!strcmp(a, "--label")) label = v;
        else { usage(); return 1; }
    }
    if (ip)
        return run_sender(ip, port, frame_bytes, fps, seconds, chunk, sndbuf, label);
    return run_receiver(port);
}
