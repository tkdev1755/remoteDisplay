/*
 * LINUX RECEIVER (C++ SDL2) - INSTRUMENTED DEBUG VERSION
 * Optimisations: Recvmmsg 64, MTU 65k, Busy Poll, Drain 28MB
 * Compile: g++ -o receiver receiver.cpp -lSDL2 -O3 -march=native
 * Run: sudo taskset -c 2 chrt -f 50 ./receiver
 */

#define _GNU_SOURCE
#include <iostream>
#include <vector>
#include <cstring>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <SDL2/SDL.h>
#include <chrono>
#include <sched.h>
#include <cerrno>
#include <cstring>
#define PORT 5000
#define MAX_UDP_PAYLOAD 65000
#define VLEN 64
#define DEBUG_COUT if(isDebugMode) std::cout

// 1. Variable globale pour stocker l'état du debug
bool isDebugMode = false;

// 2. La macro magique.
// Si isDebugMode est faux, l'instruction "if" échoue, et tout ce qui suit le << est ignoré à l'exécution.

struct __attribute__((packed)) UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--debug") == 0) {
                isDebugMode = true;
            }
    }
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);       // On vide le masque
    CPU_SET(2, &cpuset);
    if (sched_setaffinity(0, sizeof(cpu_set_t), &cpuset) != 0) {
            DEBUG_COUT << "⚠️ [Avertissement] Impossible de fixer l'affinité sur le coeur 2 : "
                       << strerror(errno) << "\n";
        } else {
            DEBUG_COUT << "✅ Affinité CPU fixée sur le coeur 2.\n";
    }

    struct sched_param param;
    param.sched_priority = 50; // Priorité de 1 (basse) à 99 (haute)

    // SCHED_FIFO est la politique temps réel (First In, First Out)
    if (sched_setscheduler(0, SCHED_FIFO, &param) != 0) {
        DEBUG_COUT << "⚠️ [Avertissement] Échec du passage en priorité temps réel SCHED_FIFO : "
                    << strerror(errno) << "\n"
                    << "   -> Avez-vous oublié d'exécuter: sudo setcap 'cap_sys_nice=eip' <executable> ?\n";
    } else {
        DEBUG_COUT << "✅ Priorité temps réel (SCHED_FIFO, niveau 50) activée.\n";
    }


    std::ios_base::sync_with_stdio(false);
    std::cin.tie(NULL);
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");
    if (SDL_Init(SDL_INIT_VIDEO) < 0) return 1;
    SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT601);

    SDL_Window* window = SDL_CreateWindow(
        "TBT RX DEBUG", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 3840, 2160,
        SDL_WINDOW_SHOWN | SDL_WINDOW_BORDERLESS
    );

    // Renderer SANS VSync
    SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture* texture = nullptr;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);

    // --- FORCE BUFFER 40MB ---
    int rcvbuf = 40 * 1024 * 1024;
    // On essaie de FORCER (root), sinon standard
    if (setsockopt(sock, SOL_SOCKET, SO_RCVBUFFORCE, &rcvbuf, sizeof(rcvbuf)) < 0) {
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    }

    int busy_poll = 50;
    setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &busy_poll, sizeof(busy_poll));

    struct timeval tv = {1, 0};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);
    bind(sock, (struct sockaddr*)&addr, sizeof(addr));

    std::vector<uint8_t> frameBuffer(15 * 1024 * 1024);

    struct mmsghdr msgs[VLEN];
    struct iovec iovecs[VLEN];
    uint8_t packetBuffers[VLEN][MAX_UDP_PAYLOAD + sizeof(UDPFrameHeader)];

    for (int i = 0; i < VLEN; i++) {
        memset(&iovecs[i], 0, sizeof(iovecs[i]));
        memset(&msgs[i], 0, sizeof(msgs[i]));
        iovecs[i].iov_base = packetBuffers[i];
        iovecs[i].iov_len = sizeof(packetBuffers[i]);
        msgs[i].msg_hdr.msg_iov = &iovecs[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }

    uint32_t currentFrameId = 0;
    int chunksReceived = 0;
    int expectedChunks = 0;
    int currentWidth = 0, currentHeight = 0;
    bool running = true;
    SDL_Event event;

    // --- VARIABLES DEBUG ---
    auto lastLogTime = std::chrono::steady_clock::now();
    uint32_t fpsCounter = 0;
    uint32_t drainCounter = 0;
    uint32_t frameLossCounter = 0;
    uint32_t maxBytesInQueue = 0;
    auto lastPacketTime = std::chrono::steady_clock::now();
    bool sleepSignalSent = false;
    SDL_ShowCursor(SDL_DISABLE);
    DEBUG_COUT << "🚀 Receiver MTU 65k (DEBUG) Ready.\n";

    while (running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT || (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE)) running = false;
        }

        // --- DRAIN LOGIC (Seuil Haut 28MB) ---
        int bytesAvailable;
        if (ioctl(sock, FIONREAD, &bytesAvailable) == 0) {
            if (bytesAvailable > (int)maxBytesInQueue) maxBytesInQueue = bytesAvailable; // Stats

            // Seuil à 28 Mo pour tolérer les bursts de 2 frames
            if (bytesAvailable > 28 * 1024 * 1024) {
                // LOG LORS D'UN DRAIN
                DEBUG_COUT << "⚠️ [DRAIN] Buffer: " << (bytesAvailable/1024/1024) << "MB. Purge !\n";
                drainCounter++;
                while (bytesAvailable > 0) {
                    if (recvmmsg(sock, msgs, VLEN, 0, NULL) <= 0) break;
                    ioctl(sock, FIONREAD, &bytesAvailable);
                }
                currentFrameId = 0; chunksReceived = 0; continue;
            }
        }

        // --- BATCH READ ---
        int numMsgs = recvmmsg(sock, msgs, VLEN, 0, NULL);
        if (numMsgs > 0) {
                    // On a reçu des paquets : on met à jour l'horloge et on réinitialise l'état
                    lastPacketTime = std::chrono::steady_clock::now();
                    if (sleepSignalSent) {
                        DEBUG_COUT << "⚡️ Réception reprise. Réinitialisation du signal de veille.\n";
                        sleepSignalSent = false;
                    }
                } else {
                    // Aucun paquet reçu. Vérifions depuis combien de temps :
                    auto now = std::chrono::steady_clock::now();
                    auto durationWithoutPackets = std::chrono::duration_cast<std::chrono::seconds>(now - lastPacketTime).count();

                    if (durationWithoutPackets >= 3 && !sleepSignalSent) {
                        // 3 secondes atteintes : Envoi de l'alerte UDP
                        int alertSock = socket(AF_INET, SOCK_DGRAM, 0);
                        if (alertSock >= 0) {
                            struct sockaddr_in destAddr = {0};
                            destAddr.sin_family = AF_INET;
                            destAddr.sin_port = htons(5002);
                            inet_pton(AF_INET, "127.0.0.1", &destAddr.sin_addr);

                            const char* alertMsg = "SLP_DETECTED";
                            sendto(alertSock, alertMsg, strlen(alertMsg), 0, (struct sockaddr*)&destAddr, sizeof(destAddr));
                            close(alertSock);

                            DEBUG_COUT << "💤 TIMEOUT: 3s sans paquet. Signal 'SLP_DETECTED' envoyé sur 127.0.0.1:5002\n";
                            sleepSignalSent = true; // On verrouille pour ne pas spammer
                        }
                    }
                    continue; // Passe à l'itération suivante de la boucle principale
                }
        for (int i = 0; i < numMsgs; i++) {
            UDPFrameHeader* header = (UDPFrameHeader*)packetBuffers[i];
            uint8_t* payload = packetBuffers[i] + sizeof(UDPFrameHeader);
            int len = msgs[i].msg_len;

            if (header->frameId > currentFrameId || (currentFrameId - header->frameId) > 500) {
                // Détection perte
                if (currentFrameId != 0 && (header->frameId > currentFrameId + 1)) {
                    frameLossCounter += (header->frameId - currentFrameId - 1);
                    DEBUG_COUT << "❌ SAUT D'IMAGE : Perdu " << (header->frameId - currentFrameId - 1) << " frames.\n";
                }

                currentFrameId = header->frameId;
                chunksReceived = 0;
                expectedChunks = header->totalChunks;

                if (header->width != currentWidth || header->height != currentHeight) {
                    currentWidth = header->width; currentHeight = header->height;
                    if (header->totalSize > frameBuffer.size()) frameBuffer.resize(header->totalSize);

                    if (texture) SDL_DestroyTexture(texture);
                    texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_NV12, SDL_TEXTUREACCESS_STREAMING, currentWidth, currentHeight);
                }
            }

            if (header->frameId == currentFrameId) {
                size_t offset = header->chunkId * MAX_UDP_PAYLOAD;
                if (offset + (len - sizeof(UDPFrameHeader)) <= frameBuffer.size()) {
                    memcpy(frameBuffer.data() + offset, payload, len - sizeof(UDPFrameHeader));
                    chunksReceived++;
                }

                if (chunksReceived >= expectedChunks && texture) {
                    SDL_UpdateTexture(texture, NULL, frameBuffer.data(), currentWidth);
                    SDL_RenderClear(renderer);
                    SDL_RenderCopy(renderer, texture, NULL, NULL);
                    SDL_RenderPresent(renderer);

                    fpsCounter++; // Compte la frame affichée
                }
            }
        }

        // --- LOG SECONDE PAR SECONDE ---
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastLogTime).count() >= 1000) {
            DEBUG_COUT << "[RX] FPS: " << fpsCounter
                      << " | Drain Events: " << drainCounter
                      << " | Frame Loss: " << frameLossCounter
                      << " | Max Buffer: " << (maxBytesInQueue / 1024.0 / 1024.0) << " MB"
                      << std::endl;

            fpsCounter = 0;
            drainCounter = 0;
            frameLossCounter = 0;
            maxBytesInQueue = 0;
            lastLogTime = now;
        }
    }

    if (texture) SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    close(sock);
    return 0;
}
