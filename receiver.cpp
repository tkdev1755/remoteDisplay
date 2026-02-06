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
#include <chrono> // Pour le logging

#define PORT 5000
#define MAX_UDP_PAYLOAD 65000
#define VLEN 64

struct __attribute__((packed)) UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

int main() {
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

    SDL_ShowCursor(SDL_DISABLE);
    std::cout << "🚀 Receiver MTU 65k (DEBUG) Ready." << std::endl;

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
                std::cout << "⚠️ [DRAIN] Buffer: " << (bytesAvailable/1024/1024) << "MB. Purge !" << std::endl;
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
        if (numMsgs <= 0) continue;

        for (int i = 0; i < numMsgs; i++) {
            UDPFrameHeader* header = (UDPFrameHeader*)packetBuffers[i];
            uint8_t* payload = packetBuffers[i] + sizeof(UDPFrameHeader);
            int len = msgs[i].msg_len;

            if (header->frameId > currentFrameId || (currentFrameId - header->frameId) > 500) {
                // Détection perte
                if (currentFrameId != 0 && (header->frameId > currentFrameId + 1)) {
                    frameLossCounter += (header->frameId - currentFrameId - 1);
                    std::cout << "❌ SAUT D'IMAGE : Perdu " << (header->frameId - currentFrameId - 1) << " frames." << std::endl;
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
            std::cout << "[RX] FPS: " << fpsCounter
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
