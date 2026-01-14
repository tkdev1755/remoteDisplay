/*
 * LINUX RECEIVER (C++ SDL2) - FINAL GOLD VERSION
 * Optimisations: Recvmmsg 64, MTU 65k, Busy Poll, Drain, Color Hack
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

#define PORT 5000
#define MAX_UDP_PAYLOAD 65000 // MTU 65k support
#define VLEN 64 // Batch size

struct __attribute__((packed)) UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

int main() {
    // 1. INIT SDL AVEC CORRECTION COULEURS
    // Hint Linear : Adoucit l'image (moins pixelisée/sharp)
    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "linear");

    if (SDL_Init(SDL_INIT_VIDEO) < 0) return 1;

    // Hack BT.601 : Force une matrice SD sur du contenu HD.
    // Effet : Désature légèrement les couleurs -> Moins agressif.
    SDL_SetYUVConversionMode(SDL_YUV_CONVERSION_BT601);

    SDL_Window* window = SDL_CreateWindow(
        "TBT RX", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, 3840, 2160,
        SDL_WINDOW_SHOWN | SDL_WINDOW_BORDERLESS
    );

    // Renderer SANS VSync pour latence minimale (Roue libre)
    SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture* texture = nullptr;

    // 2. SOCKET OPTIMISÉ
    int sock = socket(AF_INET, SOCK_DGRAM, 0);

    // Buffer Kernel 40 Mo
    int rcvbuf = 40 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

    // Busy Poll : Empêche le process de dormir (Latence ultra-faible)
    int busy_poll = 50;
    setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &busy_poll, sizeof(busy_poll));

    struct timeval tv = {1, 0};
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT);
    bind(sock, (struct sockaddr*)&addr, sizeof(addr));

    // 3. STRUCTURES BATCHING (Static Alloc)
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

    SDL_ShowCursor(SDL_DISABLE);
    std::cout << "🚀 Receiver MTU 65k Ready." << std::endl;

    while (running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT || (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE)) running = false;
        }

        // --- DRAIN LOGIC ---
        int bytesAvailable;
        if (ioctl(sock, FIONREAD, &bytesAvailable) == 0) {
            // Seuil augmenté à 30 Mo pour éviter les micro-saccades sur faux positifs
            if (bytesAvailable > 16 * 1024 * 1024) {
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
                }
            }
        }
    }

    if (texture) SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    close(sock);
    return 0;
}
