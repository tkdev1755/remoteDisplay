/*
 * LINUX RECEIVER (C++ SDL2) - VERSION MULTITHREAD
 *
 * Architecture :
 *   - Thread RÉSEAU (coeur NET_CPU, SCHED_FIFO 50) : ne fait QUE lire le socket
 *     et réassembler les frames. Ne bloque jamais sur l'affichage.
 *   - Thread AFFICHAGE = main (coeur DISPLAY_CPU, SCHED_FIFO 20) : récupère la
 *     dernière frame complète et la présente, synchronisé sur le vblank (VSync).
 *   - Échange via une "boîte aux lettres" triple-tampon : le producteur écrit
 *     dans un slot, le consommateur lit un autre, le 3e sert de zone de passage.
 *     Le consommateur voit toujours la frame la plus fraîche ; les frames
 *     intermédiaires (source 120 fps vs dalle 60 Hz) sont jetées sans douleur.
 *
 * Résultat : plus de tearing (présentation calée vblank) et plus d'à-coups de
 * drain (le socket est vidé en continu, il ne se remplit plus pendant qu'on rend).
 *
 * Compile : g++ -o receiver receiver.cpp -lSDL2 -O3 -march=native -pthread
 * Run     : sudo ./receiver --debug        (root ou setcap cap_sys_nice=eip)
 */

#define _GNU_SOURCE
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <SDL2/SDL.h>

#define PORT 5000
#define MAX_UDP_PAYLOAD 65000
#define VLEN 64
#define NET_CPU 2      // coeur dédié à la réception réseau
#define DISPLAY_CPU 3  // coeur dédié à l'affichage
// Borne haute d'une frame NV12 : 5120x2880 * 1.5 -> ~21 Mio. Les 3 slots sont
// alloués à cette taille une fois pour toutes : zéro realloc en cours de flux.
#define MAX_FRAME_BYTES (5120 * 2880 * 3 / 2)
#define DRAIN_THRESHOLD (28 * 1024 * 1024)

#define DEBUG_COUT      \
    if (isDebugMode)    \
    std::cout

bool isDebugMode = false;

struct __attribute__((packed)) UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

// ---------------------------------------------------------------------------
// Boîte aux lettres triple-tampon (single-producer / single-consumer)
// ---------------------------------------------------------------------------
class FrameMailbox {
public:
    struct Slot {
        std::vector<uint8_t> data;
        int w = 0, h = 0;
        uint32_t frameId = 0;
    };

    FrameMailbox() {
        for (auto& s : slots_) s.data.resize(MAX_FRAME_BYTES);
    }

    // --- côté producteur (thread réseau) ---
    Slot& writeSlot() { return slots_[write_]; }

    void publish(int w, int h, uint32_t id) {
        std::lock_guard<std::mutex> lk(mtx_);
        slots_[write_].w = w;
        slots_[write_].h = h;
        slots_[write_].frameId = id;
        std::swap(write_, ready_);
        fresh_ = true;
    }

    // --- côté consommateur (thread affichage) ---
    // true si une nouvelle frame vient d'être basculée dans readSlot()
    bool tryAcquire() {
        std::lock_guard<std::mutex> lk(mtx_);
        if (!fresh_) return false;
        std::swap(read_, ready_);
        fresh_ = false;
        return true;
    }
    Slot& readSlot() { return slots_[read_]; }

private:
    std::array<Slot, 3> slots_;
    std::mutex mtx_;
    int write_ = 0, ready_ = 1, read_ = 2; // toujours une permutation de {0,1,2}
    bool fresh_ = false;
};

// ---------------------------------------------------------------------------
// Compteurs de stats partagés entre les deux threads
// ---------------------------------------------------------------------------
struct Stats {
    std::atomic<uint32_t> producedFrames{0};
    std::atomic<uint32_t> drainEvents{0};
    std::atomic<uint32_t> lostFrames{0};
    std::atomic<uint32_t> maxQueueBytes{0};
};

// ---------------------------------------------------------------------------
// Épingle le thread courant sur un coeur + priorité temps réel SCHED_FIFO
// ---------------------------------------------------------------------------
static void pinThread(int cpu, int rtPrio, const char* label) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        DEBUG_COUT << "⚠️ [" << label << "] affinité coeur " << cpu << " : "
                   << strerror(errno) << "\n";
    } else {
        DEBUG_COUT << "✅ [" << label << "] épinglé coeur " << cpu << "\n";
    }

    struct sched_param sp;
    sp.sched_priority = rtPrio;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) != 0) {
        DEBUG_COUT << "⚠️ [" << label << "] SCHED_FIFO " << rtPrio << " : "
                   << strerror(errno) << " (setcap cap_sys_nice=eip ?)\n";
    } else {
        DEBUG_COUT << "✅ [" << label << "] SCHED_FIFO prio " << rtPrio << "\n";
    }
}

// ---------------------------------------------------------------------------
// THREAD RÉSEAU : lit le socket, réassemble, publie les frames complètes.
// ---------------------------------------------------------------------------
static void networkThread(FrameMailbox& mailbox, Stats& stats,
                          std::atomic<bool>& running) {
    pinThread(NET_CPU, 50, "net");

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        DEBUG_COUT << "❌ socket() : " << strerror(errno) << "\n";
        running = false;
        return;
    }

    int rcvbuf = 40 * 1024 * 1024;
    if (setsockopt(sock, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) < 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    int busy = 50;
    setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &busy, sizeof(busy));

    struct timeval tv = {1, 0}; // recvmmsg rend la main au moins 1x/s
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);
    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        DEBUG_COUT << "❌ bind() : " << strerror(errno) << "\n";
        close(sock);
        running = false;
        return;
    }

    // Buffers recvmmsg : VLEN datagrammes récupérés par appel.
    const size_t PKTSZ = MAX_UDP_PAYLOAD + sizeof(UDPFrameHeader);
    std::vector<uint8_t> pktbuf(VLEN * PKTSZ); // sur le tas, pas sur la pile
    struct mmsghdr msgs[VLEN];
    struct iovec iovecs[VLEN];
    for (int i = 0; i < VLEN; ++i) {
        memset(&msgs[i], 0, sizeof(msgs[i]));
        iovecs[i].iov_base = pktbuf.data() + i * PKTSZ;
        iovecs[i].iov_len = PKTSZ;
        msgs[i].msg_hdr.msg_iov = &iovecs[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }

    // État de réassemblage de la frame en cours.
    uint32_t curId = 0;
    int chunks = 0, expected = 0;
    int curW = 0, curH = 0;
    bool published = false;

    auto lastPacket = std::chrono::steady_clock::now();
    bool slpSent = false;

    while (running) {
        // --- Drain : si le buffer noyau enfle trop, on purge et on repart neuf ---
        int avail = 0;
        if (ioctl(sock, FIONREAD, &avail) == 0) {
            if ((uint32_t)avail > stats.maxQueueBytes.load())
                stats.maxQueueBytes.store(avail);
            if (avail > DRAIN_THRESHOLD) {
                stats.drainEvents.fetch_add(1);
                while (avail > 0) {
                    if (recvmmsg(sock, msgs, VLEN, MSG_DONTWAIT, nullptr) <= 0) break;
                    ioctl(sock, FIONREAD, &avail);
                }
                curId = 0;
                chunks = 0;
                published = false;
                continue;
            }
        }

        // --- Lecture par lot ---
        int n = recvmmsg(sock, msgs, VLEN, 0, nullptr);
        if (n <= 0) {
            // Timeout : aucun paquet. Après 5 s -> signal de veille au helper.
            auto now = std::chrono::steady_clock::now();
            auto silent =
                std::chrono::duration_cast<std::chrono::seconds>(now - lastPacket)
                    .count();
            if (silent >= 5 && !slpSent) {
                int a = socket(AF_INET, SOCK_DGRAM, 0);
                if (a >= 0) {
                    struct sockaddr_in d = {};
                    d.sin_family = AF_INET;
                    d.sin_port = htons(5002);
                    inet_pton(AF_INET, "127.0.0.1", &d.sin_addr);
                    const char* m = "SLP_DETECTED";
                    sendto(a, m, strlen(m), 0, (struct sockaddr*)&d, sizeof(d));
                    close(a);
                    DEBUG_COUT << "💤 5 s sans paquet -> SLP_DETECTED\n";
                    slpSent = true;
                }
            }
            continue;
        }
        lastPacket = std::chrono::steady_clock::now();
        slpSent = false;

        for (int i = 0; i < n; ++i) {
            auto* h = reinterpret_cast<UDPFrameHeader*>(iovecs[i].iov_base);
            uint8_t* payload =
                (uint8_t*)iovecs[i].iov_base + sizeof(UDPFrameHeader);
            int plen = (int)msgs[i].msg_len - (int)sizeof(UDPFrameHeader);
            if (plen < 0) continue;

            // Début d'une nouvelle frame ? (id plus grand, ou grand écart = reset)
            if (h->frameId > curId || (curId - h->frameId) > 500) {
                if (curId != 0 && h->frameId > curId + 1)
                    stats.lostFrames.fetch_add(h->frameId - curId - 1);
                curId = h->frameId;
                chunks = 0;
                expected = h->totalChunks;
                curW = h->width;
                curH = h->height;
                published = false;
            }

            if (h->frameId != curId || published) continue; // chunk hors sujet

            size_t off = (size_t)h->chunkId * MAX_UDP_PAYLOAD;
            std::vector<uint8_t>& wb = mailbox.writeSlot().data;
            if (off + (size_t)plen <= wb.size()) {
                memcpy(wb.data() + off, payload, plen);
                chunks++;
            }

            // Frame complète -> on la publie (bascule de slot) et on passe à la suite
            if (expected > 0 && chunks >= expected) {
                mailbox.publish(curW, curH, curId);
                stats.producedFrames.fetch_add(1);
                published = true;
            }
        }
    }

    close(sock);
}

// ---------------------------------------------------------------------------
// MAIN = THREAD AFFICHAGE
// ---------------------------------------------------------------------------
int main(int argc, char* argv[]) {
    int forcedW = 0, forcedH = 0;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--debug") == 0)
            isDebugMode = true;
        else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc)
            forcedW = atoi(argv[++i]);
        else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc)
            forcedH = atoi(argv[++i]);
    }
    const bool followStream = (forcedW <= 0 || forcedH <= 0);

    std::ios_base::sync_with_stdio(false);
    if (SDL_Init(SDL_INIT_VIDEO) < 0) return 1;

    // Matrice de conversion YCbCr->RGB : Rec.709 (cf. sender en Display P3).
    SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT709);

    // --- Choix du mode d'affichage : on prend la plus haute définition offerte
    //     (ou celle forcée), puis un vrai modeset via SDL_WINDOW_FULLSCREEN. ---
    SDL_DisplayMode targetMode;
    SDL_zero(targetMode);
    bool haveMode = false;
    const int nModes = SDL_GetNumDisplayModes(0);
    for (int m = 0; m < nModes; ++m) {
        SDL_DisplayMode dm;
        if (SDL_GetDisplayMode(0, m, &dm) != 0) continue;
        if (forcedW > 0 && forcedH > 0) {
            if (dm.w == forcedW && dm.h == forcedH &&
                (!haveMode || dm.refresh_rate > targetMode.refresh_rate)) {
                targetMode = dm;
                haveMode = true;
            }
        } else if (!haveMode || (long long)dm.w * dm.h >
                                    (long long)targetMode.w * targetMode.h) {
            targetMode = dm;
            haveMode = true;
        }
    }
    if (!haveMode) {
        if (SDL_GetDesktopDisplayMode(0, &targetMode) != 0) {
            SDL_zero(targetMode);
            targetMode.w = 3840;
            targetMode.h = 2160;
            targetMode.refresh_rate = 60;
        }
    }
    int panelW = targetMode.w;
    int panelH = targetMode.h;
    DEBUG_COUT << "🖥️  Mode retenu : " << panelW << "x" << panelH << " @ "
               << targetMode.refresh_rate << "Hz\n";

    SDL_Window* window = SDL_CreateWindow(
        "TBT RX", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, panelW, panelH,
        SDL_WINDOW_FULLSCREEN | SDL_WINDOW_HIDDEN);
    if (window && haveMode) SDL_SetWindowDisplayMode(window, &targetMode);
    if (window) SDL_ShowWindow(window);

    // Renderer AVEC VSync : SDL_RenderPresent bloquera jusqu'au page-flip vblank.
    // Possible sans à-coups uniquement parce que la réception vit dans un autre
    // thread (elle continue de vider le socket pendant qu'on attend le vblank).
    SDL_Renderer* renderer = SDL_CreateRenderer(
        window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);

    SDL_Texture* texture = nullptr;
    int texW = 0, texH = 0;

    // (Re)configure la sortie quand la définition du flux change.
    auto applyStreamResolution = [&](int w, int h) {
        if (followStream && (w != panelW || h != panelH)) {
            SDL_DisplayMode want;
            SDL_zero(want);
            want.w = w;
            want.h = h;
            SDL_DisplayMode got;
            if (SDL_GetClosestDisplayMode(0, &want, &got) && got.w == w &&
                got.h == h) {
                SDL_SetWindowFullscreen(window, 0);
                SDL_SetWindowSize(window, got.w, got.h);
                SDL_SetWindowDisplayMode(window, &got);
                SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN);
                DEBUG_COUT << "🔄 Recalage dalle -> " << got.w << "x" << got.h
                           << " @ " << got.refresh_rate << "Hz\n";
            }
            int ow = panelW, oh = panelH;
            SDL_GetRendererOutputSize(renderer, &ow, &oh);
            if (ow > 0 && oh > 0) {
                panelW = ow;
                panelH = oh;
            }
            SDL_RenderSetLogicalSize(renderer, panelW, panelH);
        }

        const bool match = (w == panelW && h == panelH);
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, match ? "0" : "1");
        if (match) {
            DEBUG_COUT << "✅ Flux " << w << "x" << h
                       << " == dalle : 1:1 plein écran.\n";
        } else if (w <= panelW && h <= panelH) {
            DEBUG_COUT << "ℹ️ Flux " << w << "x" << h << " < dalle : 1:1 centré.\n";
        } else {
            DEBUG_COUT << "⚠️ Flux " << w << "x" << h << " > dalle : réduction.\n";
        }

        if (texture) SDL_DestroyTexture(texture);
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_NV12,
                                    SDL_TEXTUREACCESS_STREAMING, w, h);
        texW = w;
        texH = h;
    };

    // --- Démarrage du thread réseau ---
    FrameMailbox mailbox;
    Stats stats;
    std::atomic<bool> running{true};
    std::thread net(networkThread, std::ref(mailbox), std::ref(stats),
                    std::ref(running));

    pinThread(DISPLAY_CPU, 20, "display");
    SDL_ShowCursor(SDL_DISABLE);
    DEBUG_COUT << "🚀 Receiver multithread prêt.\n";

    auto lastLog = std::chrono::steady_clock::now();
    uint32_t displayedFps = 0;

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT ||
                (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE))
                running = false;
        }

        if (mailbox.tryAcquire()) {
            FrameMailbox::Slot& slot = mailbox.readSlot();

            if (slot.w != texW || slot.h != texH)
                applyStreamResolution(slot.w, slot.h);

            if (texture) {
                SDL_UpdateTexture(texture, nullptr, slot.data.data(), texW);
                SDL_RenderClear(renderer);
                if (texW <= panelW && texH <= panelH) {
                    SDL_Rect dst = {(panelW - texW) / 2, (panelH - texH) / 2,
                                    texW, texH};
                    SDL_RenderCopy(renderer, texture, nullptr, &dst);
                } else {
                    SDL_RenderCopy(renderer, texture, nullptr, nullptr);
                }
                SDL_RenderPresent(renderer); // <-- bloque sur le vblank
                displayedFps++;
            }
        } else {
            SDL_Delay(1); // pas de frame neuve : on rend la main brièvement
        }

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastLog)
                .count() >= 1000) {
            DEBUG_COUT << "[RX] Affichées: " << displayedFps
                       << " | Produites: " << stats.producedFrames.exchange(0)
                       << " | Drain: " << stats.drainEvents.exchange(0)
                       << " | Pertes: " << stats.lostFrames.exchange(0)
                       << " | Buffer max: "
                       << (stats.maxQueueBytes.exchange(0) / 1048576.0) << " MB\n";
            displayedFps = 0;
            lastLog = now;
        }
    }

    running = false;
    if (net.joinable()) net.join();

    if (texture) SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
