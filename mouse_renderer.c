/*
 * Compile: gcc -o mouse_renderer mouse_renderer.c $(sdl2-config --cflags --libs) -lSDL2_image -lpthread
 */
#include <SDL2/SDL.h>
#include <SDL2/SDL_image.h> // Nouvelle include
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <pthread.h>

#define PORT 9000

// --- Globals ---
volatile int g_mouse_x = 0;
volatile int g_mouse_y = 0;
volatile int g_running = 1;

// Packet Structure
typedef struct __attribute__((packed)) {
    uint16_t x;
    uint16_t y;
    uint8_t  flags;
} MousePacket;

// --- Network Thread (Optimisé avec MSG_DONTWAIT) ---
void *network_thread(void *arg) {
    int sockfd;
    struct sockaddr_in servaddr;
    MousePacket packet;

    if ((sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) return NULL;

    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(PORT);

    if (bind(sockfd, (const struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) return NULL;

    // Timeout de sécurité pour ne pas bloquer indéfiniment
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 1000; // 1ms
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof tv);

    while (g_running) {
        // On vide le buffer pour ne garder que la DERNIERE position (Anti-Lag)
        while (recvfrom(sockfd, &packet, sizeof(packet), 0, NULL, NULL) > 0) {
            g_mouse_x = ntohs(packet.x);
            g_mouse_y = ntohs(packet.y);
        }
        // Petit sleep pour ne pas manger 100% du CPU dans ce thread
        usleep(500);
    }
    close(sockfd);
    return NULL;
}

int main(int argc, char *argv[]) {
    SDL_Init(SDL_INIT_VIDEO);
    IMG_Init(IMG_INIT_PNG); // Init du module image

    SDL_DisplayMode dm;
    SDL_GetCurrentDisplayMode(0, &dm);

    SDL_Window *window = SDL_CreateWindow(
        "Thunderbolt Cursor",
        0, 0, dm.w, dm.h,
        SDL_WINDOW_BORDERLESS | SDL_WINDOW_ALWAYS_ON_TOP | SDL_WINDOW_SKIP_TASKBAR
    );

    // Renderer avec VSync pour une fluidité parfaite
    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);

    // Charger l'image du curseur
    SDL_Surface *surface = IMG_Load("cursor.png");
    if (!surface) {
        printf("Erreur: Impossible de charger cursor.png\n");
        return 1;
    }
    SDL_Texture *cursor_texture = SDL_CreateTextureFromSurface(renderer, surface);
    SDL_FreeSurface(surface);

    pthread_t net_tid;
    pthread_create(&net_tid, NULL, network_thread, NULL);

    SDL_Event event;
    while (g_running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT || (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_ESCAPE))
                g_running = 0;
        }

        // 1. Effacer (Transparent)
        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
        SDL_RenderClear(renderer);

        // 2. Dessiner la texture (Sprite)
        // Ajuste w et h selon la taille de ton image PNG (ex: 32x32)
        SDL_Rect dest_rect = { g_mouse_x, g_mouse_y, 32, 32 };
        SDL_RenderCopy(renderer, cursor_texture, NULL, &dest_rect);

        // 3. Afficher
        SDL_RenderPresent(renderer);
    }

    SDL_DestroyTexture(cursor_texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
