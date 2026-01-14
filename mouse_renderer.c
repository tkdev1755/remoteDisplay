/*
 * Compile avec :
 * gcc -o mouse_renderer mouse_renderer.c $(pkg-config --cflags --libs sdl3) -lSDL3_image -lpthread
 */
#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <pthread.h>

#define PORT 9000

volatile int g_mouse_x = 0;
volatile int g_mouse_y = 0;
volatile int g_running = 1;

typedef struct __attribute__((packed)) {
    uint16_t x;
    uint16_t y;
    uint8_t  flags;
} MousePacket;

// --- Thread Réseau (Inchangé) ---
void *network_thread(void *arg) {
    int sockfd;
    struct sockaddr_in servaddr;
    MousePacket packet;

    if ((sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) return NULL;

    int opt = 1;
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_INET;
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(PORT);

    if (bind(sockfd, (const struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) return NULL;

    struct timeval tv = {0, 1000};
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof tv);

    while (g_running) {
        while (recvfrom(sockfd, &packet, sizeof(packet), 0, NULL, NULL) > 0) {
            g_mouse_x = ntohs(packet.x);
            g_mouse_y = ntohs(packet.y);
        }
        usleep(500);
    }
    close(sockfd);
    return NULL;
}

// --- Main (Adapté SDL3) ---
int main(int argc, char *argv[]) {
    // 1. Init SDL3
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "SDL3 Init failed: %s\n", SDL_GetError());
        return 1;
    }

    // 2. Init SDL3_Image (Renvoie 0 si échec, contrairement à SDL2 qui renvoyait des flags)
    // Note: Dans les versions récentes de SDL3_image, IMG_Init peut ne plus être requis explicitement
    // pour charger des PNG, mais on le garde pour la compatibilité.
    // S'il échoue à linker, on peut commenter cette ligne et IMG_Quit.
    // IMG_Init(IMG_INIT_PNG);

    const SDL_DisplayMode *dm = SDL_GetCurrentDisplayMode(SDL_GetPrimaryDisplay());
    int w = dm ? dm->w : 1920;
    int h = dm ? dm->h : 1080;

    // 3. Création Fenêtre avec TRANSPARENCE
    SDL_Window *window = SDL_CreateWindow("Thunderbolt Cursor", w, h,
        SDL_WINDOW_BORDERLESS | SDL_WINDOW_ALWAYS_ON_TOP | SDL_WINDOW_TRANSPARENT | SDL_WINDOW_UTILITY);

    if (!window) {
        fprintf(stderr, "Window creation failed: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Renderer *renderer = SDL_CreateRenderer(window, NULL);
    if (!renderer) return 1;

    // 4. Chargement de l'image (Syntaxe SDL3)
    SDL_Surface *surface = IMG_Load("cursor.png");
    SDL_Texture *cursor_texture = NULL;

    if (surface) {
        cursor_texture = SDL_CreateTextureFromSurface(renderer, surface);
        SDL_DestroySurface(surface); // REMPLACEMENT DE SDL_FreeSurface
    } else {
        printf("Attention: cursor.png introuvable, utilisation d'un carré rouge.\n");
    }

    pthread_t net_tid;
    pthread_create(&net_tid, NULL, network_thread, NULL);

    SDL_Event event;
    while (g_running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT ||
               (event.type == SDL_EVENT_KEY_DOWN && event.key.key == SDLK_ESCAPE)) {
                g_running = 0;
            }
        }

        // Effacer en transparent
        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
        SDL_RenderClear(renderer);

        // Position avec des FLOTTANTS (SDL3)
        // Ajuste 32.0f selon la taille de ton image
        SDL_FRect dest_rect = { (float)g_mouse_x, (float)g_mouse_y, 32.0f, 32.0f };

        if (cursor_texture) {
            // REMPLACEMENT DE SDL_RenderCopy
            SDL_RenderTexture(renderer, cursor_texture, NULL, &dest_rect);
        } else {
            // Fallback carré rouge
            SDL_SetRenderDrawColor(renderer, 255, 0, 0, 255);
            SDL_RenderFillRect(renderer, &dest_rect);
        }

        SDL_RenderPresent(renderer);
    }

    if (cursor_texture) SDL_DestroyTexture(cursor_texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    // IMG_Quit();
    SDL_Quit();
    return 0;
}
