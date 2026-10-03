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
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
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

// Horloge monotone en nanosecondes (même base pour les deux threads).
static inline int64_t nowNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

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
        int64_t tFirstNs = 0;   // arrivée du 1er chunk de la frame (mesure de latence)
        int64_t tPublishNs = 0; // frame complète, publiée par le thread réseau
    };

    FrameMailbox() {
        for (auto& s : slots_) s.data.resize(MAX_FRAME_BYTES);
    }

    // --- côté producteur (thread réseau) ---
    Slot& writeSlot() { return slots_[write_]; }

    void publish(int w, int h, uint32_t id, int64_t tFirstNs, int64_t tPublishNs) {
        std::lock_guard<std::mutex> lk(mtx_);
        slots_[write_].w = w;
        slots_[write_].h = h;
        slots_[write_].frameId = id;
        slots_[write_].tFirstNs = tFirstNs;
        slots_[write_].tPublishNs = tPublishNs;
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
    int64_t curFirstNs = 0; // instant d'arrivée du 1er chunk de la frame courante
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
        // MSG_WAITFORONE : bloque jusqu'au PREMIER datagramme seulement, puis
        // vide ce qui est déjà là sans attendre. Sans ce flag, recvmmsg() sur un
        // socket bloquant attend d'avoir VLEN datagrammes : la fin d'une frame
        // (218 chunks = 3 lots de 64 + 26 restants) restait coincée tant que 38
        // chunks de la frame SUIVANTE n'étaient pas arrivés -> +1 période de
        // frame de latence sur CHAQUE image.
        int n = recvmmsg(sock, msgs, VLEN, MSG_WAITFORONE, nullptr);
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
                curFirstNs = nowNs();
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
                mailbox.publish(curW, curH, curId, curFirstNs, nowNs());
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
    bool lateLatch = true;       // --no-latelatch pour désactiver
    bool doubleBuffer = true;    // --triple-buffer pour revenir au défaut SDL
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--debug") == 0)
            isDebugMode = true;
        else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc)
            forcedW = atoi(argv[++i]);
        else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc)
            forcedH = atoi(argv[++i]);
        else if (strcmp(argv[i], "--no-latelatch") == 0)
            lateLatch = false;
        else if (strcmp(argv[i], "--triple-buffer") == 0)
            doubleBuffer = false;
    }
    const bool followStream = (forcedW <= 0 || forcedH <= 0);

    std::ios_base::sync_with_stdio(false);

    // Double buffering KMS : SDL attend le vblank juste après avoir posté le
    // flip, au lieu de laisser une 3e image en file. Le défaut (triple) coûte
    // une frame complète de latence (16,6 ms @60 Hz). À poser AVANT la fenêtre.
    if (doubleBuffer) SDL_SetHint("SDL_VIDEO_DOUBLE_BUFFER", "1");

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

    // --- Pacing "late-latch" ---------------------------------------------------
    // Idée : au lieu de prendre la frame dès que le vblank précédent est passé
    // (elle vieillirait ~16 ms avant d'être scannée), on dort jusqu'à
    // (prochain vblank - budget) puis on prend la frame LA PLUS FRAÎCHE, on la
    // rend et on la présente juste à temps. `budget` = durée de rendu + marge,
    // ajustée en continu : plus tôt si on rate un vblank, plus tard si on a trop
    // de marge. Repose sur : RenderPresent (double buffer + vsync) revient au
    // vblank. Si ce n'est pas le cas (Present non bloquant), on désactive.
    double nominalPeriodNs =
        1e9 / (targetMode.refresh_rate > 0 ? targetMode.refresh_rate : 60);
    double periodNs = nominalPeriodNs;  // affiné par mesure
    int64_t lastFlipNs = 0;             // instant où le dernier Present est revenu
    double budgetNs = 5.0e6;            // avance sur le vblank (départ prudent)
    int noBlockStreak = 0;
    bool waited = false;                // déjà dormi pour ce vblank ?
    int64_t wakeNs = 0;

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
                // Le modeset casse la phase vblank : on repart de zéro.
                nominalPeriodNs =
                    1e9 / (got.refresh_rate > 0 ? got.refresh_rate : 60);
                periodNs = nominalPeriodNs;
                lastFlipNs = 0;
                budgetNs = 5.0e6;
                noBlockStreak = 0;
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

    // Accumulateur de mesures de latence (moyenne + max sur 1 s, en ms).
    struct Acc {
        double sum = 0, mx = 0;
        uint32_t n = 0;
        void add(double v) { sum += v; if (v > mx) mx = v; ++n; }
        double avg() const { return n ? sum / n : 0.0; }
        void reset() { sum = mx = 0; n = 0; }
    };
    Acc aWire, aMailbox, aRender, aPresent, aTotal;

    DEBUG_COUT << "⏱️  late-latch: " << (lateLatch ? "ON" : "OFF")
               << " | double buffer: " << (doubleBuffer ? "ON" : "OFF") << "\n";

    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT ||
                (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE))
                running = false;
        }

        // --- late-latch : on dort jusqu'à (prochain vblank - budget) ---
        // Projection du vblank à partir du dernier retour de Present, puis
        // `waited` évite de redormir tant qu'on n'a pas présenté une frame.
        if (lateLatch && lastFlipNs != 0 && !waited) {
            const int64_t now = nowNs();
            const int64_t k = (int64_t)((now - lastFlipNs) / periodNs) + 1;
            const int64_t nextV = lastFlipNs + (int64_t)(k * periodNs);
            wakeNs = nextV - (int64_t)budgetNs;
            if (wakeNs > now) {
                std::this_thread::sleep_until(std::chrono::steady_clock::time_point(
                    std::chrono::nanoseconds(wakeNs)));
            }
            waited = true;
        }

        if (mailbox.tryAcquire()) {
            const int64_t tAcq = nowNs();
            FrameMailbox::Slot& slot = mailbox.readSlot();

            if (slot.w != texW || slot.h != texH)
                applyStreamResolution(slot.w, slot.h);

            if (texture) {
                SDL_UpdateTexture(texture, nullptr, slot.data.data(), texW);
                const bool fullCover = (texW == panelW && texH == panelH);
                // Plein écran 1:1 : chaque pixel est réécrit, le clear est du
                // travail GPU perdu. Bandes noires : on garde le clear.
                if (!fullCover) SDL_RenderClear(renderer);
                if (texW <= panelW && texH <= panelH) {
                    SDL_Rect dst = {(panelW - texW) / 2, (panelH - texH) / 2,
                                    texW, texH};
                    SDL_RenderCopy(renderer, texture, nullptr, &dst);
                } else {
                    SDL_RenderCopy(renderer, texture, nullptr, nullptr);
                }
                const int64_t tBefore = nowNs();
                SDL_RenderPresent(renderer); // <-- bloque sur le vblank
                const int64_t tDone = nowNs();
                displayedFps++;

                // --- mesures : où part le temps entre la 1re donnée reçue et le flip ---
                aWire.add((slot.tPublishNs - slot.tFirstNs) / 1e6);   // réseau + réassemblage
                aMailbox.add((tAcq - slot.tPublishNs) / 1e6);          // attente en boîte
                aRender.add((tBefore - tAcq) / 1e6);                   // upload + rendu CPU
                aPresent.add((tDone - tBefore) / 1e6);                 // attente vblank
                aTotal.add((tDone - slot.tFirstNs) / 1e6);             // total

                // --- suivi de phase vblank + contrôleur du budget ---
                const int64_t blockNs = tDone - tBefore;
                if (lastFlipNs != 0) {
                    const double interval = (double)(tDone - lastFlipNs);
                    if (interval > 0.85 * nominalPeriodNs &&
                        interval < 1.15 * nominalPeriodNs)
                        periodNs = 0.98 * periodNs + 0.02 * interval;
                }
                lastFlipNs = tDone;
                waited = false;

                if (lateLatch) {
                    // Garde-fou : Present qui ne bloque jamais (pas de vsync réel)
                    // alors que le budget est déjà au maximum -> pacing impossible.
                    if (blockNs < 500000 && budgetNs >= 0.79 * periodNs) {
                        if (++noBlockStreak >= 30) {
                            lateLatch = false;
                            DEBUG_COUT << "⚠️ Present ne bloque pas sur le vblank : "
                                          "late-latch désactivé.\n";
                        }
                    } else {
                        noBlockStreak = 0;
                    }

                    // On n'apprend que des frames réellement servies "à l'heure".
                    const bool onSchedule = wakeNs != 0 && (tAcq - wakeNs) < 1000000;
                    if (onSchedule) {
                        const double cap = 0.8 * periodNs;
                        if ((double)blockNs > cap) {
                            // vblank raté (flip repoussé d'une période) : plus de marge
                            budgetNs = std::min(budgetNs + 1.5e6, cap);
                        } else {
                            // viser ~2 ms de marge entre fin de rendu et vblank
                            budgetNs -= 0.05 * ((double)blockNs - 2.0e6);
                            if (budgetNs < 2.5e6) budgetNs = 2.5e6;
                            if (budgetNs > cap) budgetNs = cap;
                        }
                    }
                }
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
            if (aTotal.n > 0) {
                char buf[256];
                snprintf(buf, sizeof(buf),
                         "[LAT ms moy(max)] réseau %.1f(%.1f) | boîte %.1f(%.1f) | "
                         "rendu %.1f(%.1f) | vblank %.1f(%.1f) | TOTAL %.1f(%.1f)"
                         " | budget %.1f",
                         aWire.avg(), aWire.mx, aMailbox.avg(), aMailbox.mx,
                         aRender.avg(), aRender.mx, aPresent.avg(), aPresent.mx,
                         aTotal.avg(), aTotal.mx, budgetNs / 1e6);
                DEBUG_COUT << buf << "\n";
            }
            aWire.reset(); aMailbox.reset(); aRender.reset();
            aPresent.reset(); aTotal.reset();
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
