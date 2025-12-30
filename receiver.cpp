/*
 * LINUX RECEIVER (C++) - UDP THUNDERBOLT OPTIMIZED (SDL2)
 * - Port 5000 : Réception Vidéo (Assemblage des chunks)
 * - Port 5001 : Réception Souris (Position seulement)
 * - Affichage : SDL2 (Affiche la vidéo + un point rouge pour la souris distante)
 */

#include <iostream>
#include <vector>
#include <thread>
#include <mutex>
#include <map>
#include <cstring>
#include <SDL2/SDL.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include "common.h" // Doit contenir MousePacket { int32_t x; int32_t y; };

#define PORT_VIDEO 5000
#define PORT_MOUSE 5001
#define MAX_BUFFER 65535

// Doit correspondre à la structure du Sender
struct UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

// Structure pour l'assemblage des paquets vidéo
struct PendingFrame {
    uint32_t receivedChunks;
    std::vector<uint8_t> data;
};

// État partagé entre les threads réseau et le thread de rendu
struct AppState {
    std::mutex mtx;
    std::vector<uint8_t> videoPixels;
    int videoWidth = 0;
    int videoHeight = 0;
    bool newFrameReady = false;

    int mouseX = 0;
    int mouseY = 0;
    bool running = true;
};

// Instance globale pour simplifier l'accès depuis les threads
AppState appState;

// Thread de réception Souris (Port 5001)
void mouseListener() {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("Socket Mouse failed"); return; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT_MOUSE);

    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("Bind Mouse failed");
        return;
    }

    std::cout << "Thread Souris écoute sur le port " << PORT_MOUSE << std::endl;

    MousePacket packet;
    while (appState.running) {
        // recvfrom est bloquant. En production, utilisez un timeout ou select() pour quitter proprement.
        ssize_t len = recvfrom(sock, &packet, sizeof(packet), 0, NULL, NULL);
        if (len == sizeof(packet)) {
            std::lock_guard<std::mutex> lock(appState.mtx);
            appState.mouseX = packet.x;
            appState.mouseY = packet.y;
        }
    }
    close(sock);
}

// Thread de réception Vidéo (Port 5000)
void videoListener() {
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("Socket Video failed"); return; }

    // Augmentation du buffer de réception système pour gérer le débit Thunderbolt
    int rcvBuff = 4 * 1024 * 1024; // 4MB
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvBuff, sizeof(rcvBuff));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(PORT_VIDEO);

    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("Bind Video failed");
        return;
    }

    std::cout << "Thread Vidéo écoute sur le port " << PORT_VIDEO << " (MTU 9000 mode)" << std::endl;

    std::vector<uint8_t> buffer(MAX_BUFFER);
    std::map<uint32_t, PendingFrame> frameBuffer;

    // Doit correspondre au MAX_UDP_PAYLOAD du sender (Optimisé Thunderbolt)
    const size_t CHUNK_PAYLOAD_SIZE = 8900;

    while (appState.running) {
        ssize_t len = recvfrom(sock, buffer.data(), MAX_BUFFER, 0, NULL, NULL);
        if (len < (ssize_t)sizeof(UDPFrameHeader)) continue;

        UDPFrameHeader* header = (UDPFrameHeader*)buffer.data();
        size_t dataSize = len - sizeof(UDPFrameHeader);
        uint8_t* dataPtr = buffer.data() + sizeof(UDPFrameHeader);

        // -- Logique d'assemblage des fragments --
        PendingFrame& frame = frameBuffer[header->frameId];

        // Premier fragment reçu pour cette frame ? On alloue.
        if (frame.data.empty()) {
            // Sécurité anti-bug (50MB max pour buffer frame 4K+BGRA)
            if (header->totalSize > 50000000) {
                 frameBuffer.erase(header->frameId);
                 continue;
            }
            frame.data.resize(header->totalSize);
            frame.receivedChunks = 0;
        }

        // Copie des données au bon offset
        // L'offset se calcule via l'ID du chunk et la taille FIXE du payload
        size_t offset = header->chunkId * CHUNK_PAYLOAD_SIZE;

        if (offset + dataSize <= frame.data.size()) {
            memcpy(frame.data.data() + offset, dataPtr, dataSize);
            frame.receivedChunks++;
        }

        // Si la frame est COMPLÈTE
        if (frame.receivedChunks >= header->totalChunks) {
            std::lock_guard<std::mutex> lock(appState.mtx);

            // Mise à jour de l'état pour l'affichage SDL
            appState.videoWidth = header->width;
            appState.videoHeight = header->height;
            appState.videoPixels = frame.data;
            appState.newFrameReady = true;

            // Nettoyage de la frame traitée
            frameBuffer.erase(header->frameId);

            // Garbage Collection simple : supprimer les très vieilles frames incomplètes
            if (frameBuffer.size() > 10) {
                auto it = frameBuffer.begin();
                while (it != frameBuffer.end()) {
                    if (it->first < header->frameId - 10) it = frameBuffer.erase(it);
                    else ++it;
                }
            }
        }
    }
    close(sock);
}

int main(int argc, char* argv[]) {
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std::cerr << "Erreur SDL: " << SDL_GetError() << std::endl;
        return 1;
    }

    // Fenêtre SDL
    SDL_Window* window = SDL_CreateWindow("Récepteur Thunderbolt - Visualisation",
                                          SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                          1280, 720, SDL_WINDOW_RESIZABLE);
    if (!window) return 1;

    SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (!renderer) return 1;

    SDL_Texture* texture = nullptr;
    int texWidth = 0, texHeight = 0;

    // Lancement des threads en arrière-plan
    std::thread tMouse(mouseListener);
    std::thread tVideo(videoListener);
    tMouse.detach();
    tVideo.detach();

    SDL_Event event;
    while (appState.running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) {
                appState.running = false;
            }
        }

        // Section critique : Lecture des données reçues et mise à jour Texture
        {
            std::lock_guard<std::mutex> lock(appState.mtx);

            // Si la résolution vidéo a changé ou si c'est la première frame
            if (appState.videoWidth > 0 && (appState.videoWidth != texWidth || appState.videoHeight != texHeight)) {
                if (texture) SDL_DestroyTexture(texture);
                texWidth = appState.videoWidth;
                texHeight = appState.videoHeight;
                // BGRA32 correspond souvent au format natif Mac (kCVPixelFormatType_32BGRA)
                texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_BGRA32,
                                            SDL_TEXTUREACCESS_STREAMING,
                                            texWidth, texHeight);
            }

            // Si une nouvelle image complète est arrivée, on met à jour la texture GPU
            if (appState.newFrameReady && texture) {
                SDL_UpdateTexture(texture, NULL, appState.videoPixels.data(), texWidth * 4);
                appState.newFrameReady = false;
            }

            // --- RENDU ---
            SDL_RenderClear(renderer);

            // 1. Dessiner la vidéo
            if (texture) {
                SDL_RenderCopy(renderer, texture, NULL, NULL);
            }

            // 2. Dessiner le point rouge (Souris)
            if (texWidth > 0 && texHeight > 0) {
                // Calcul de l'échelle entre la résolution vidéo reçue et la fenêtre actuelle
                int winW, winH;
                SDL_GetWindowSize(window, &winW, &winH);

                // Le sender envoie les coordonnées brutes (ex: 3000x2000), il faut les adapter à la fenêtre SDL
                float scaleX = (float)winW / texWidth;
                float scaleY = (float)winH / texHeight;

                SDL_Rect mouseRect;
                mouseRect.x = (int)(appState.mouseX * scaleX);
                mouseRect.y = (int)(appState.mouseY * scaleY);
                mouseRect.w = 10; // Largeur du point
                mouseRect.h = 10; // Hauteur du point

                SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255); // ROUGE
                SDL_RenderFillRect(renderer, &mouseRect);

                // Reset couleur noire pour le prochain clear
                SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
            }
        }

        SDL_RenderPresent(renderer);
        SDL_Delay(16); // ~60 FPS
    }

    // Nettoyage
    if (texture) SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return 0;
}
