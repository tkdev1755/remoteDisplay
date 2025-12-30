/*
 * mouse_receiver.c
 * Compile: gcc -o mouse_receiver mouse_receiver.c
 * Run: ./mouse_receiver
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#define PORT 9000
#define BUFFER_SIZE 1024

// Doit correspondre exactement à la structure du Sender macOS
typedef struct __attribute__((packed)) {
    uint16_t x;
    uint16_t y;
    uint8_t  flags;
} MousePacket;

int main() {
    struct sockaddr_in servaddr, cliaddr;
    MousePacket packet;

    // 1. Création du socket UDP
    int sockFD = 0;
    int cliLen;
    if ((sockFD = socket(AF_INET, SOCK_DGRAM, 0)) < 0){
     perror("Error while creating socket");
    }
    struct sockaddr_in serv_addr;
    struct sockaddr_in cliAddr;
    bzero(&serv_addr, sizeof(struct sockaddr_in));
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(9000);

    serv_addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(sockFD,&serv_addr, sizeof(serv_addr)) < 0){
        perror("Error while binding");
    }
    MousePacket* data = calloc(1, sizeof(MousePacket));

    printf("--- Thunderbolt Mouse Receiver ---\n");

    printf("Bouge la souris sur le Mac pour voir les données !\n");


    while (1) {
        // 4. Réception bloquante (attend un paquet)
        int recvResult = recvfrom(sockFD,&packet,8,0,&cliAddr,&cliLen);

        if (recvResult < 0){
            write(0,"Error while receiving packet", 29);
            perror("Error while receiving packet");
        }
        if (recvResult == sizeof(MousePacket)) {
            // 5. Conversion Endianness (Network -> Host)
            // Le Mac envoie en Big Endian (via htons), ton PC Linux est probablement Little Endian (x86/ARM)
            // Si on ne fait pas ntohs, X=10 devient X=2560
            printf("X from network -> %d\n", packet.x);
            printf("Y from network -> %d\n", packet.y);
            uint16_t true_x = ntohs(packet.x);
            uint16_t true_y = ntohs(packet.y);

            // \r permet d'écraser la ligne pour faire un effet "compteur" propre
                    // Utilise \n si tu veux voir l'historique de tous les paquets
            printf("\rReçu de %s : X=%-5d Y=%-5d Flags=%d\n",
                   inet_ntoa(cliaddr.sin_addr), true_x, true_y, packet.flags);
        }
    }

    close(sockFD);
    return 0;
}
