/*
 * MAC SENDER (Objective-C++) - UDP THUNDERBOLT OPTIMIZED
 * Utilise deux sockets UDP distinctes pour la vidéo et la souris.
 * Optimisé pour MTU 9000 (Jumbo Frames).
 * AJOUT : Binding explicite sur l'IP locale pour forcer l'interface Thunderbolt.
 */

#include <iostream>
#include <vector>
#include <thread>
#include <atomic>
#include <chrono>
#include <mutex>
#include <cmath>

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ApplicationServices/ApplicationServices.h>

#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include "common.h"

// Ports définis pour la séparation des flux
#define PORT_VIDEO 5000
#define PORT_MOUSE 5001

// OPTIMISATION THUNDERBOLT (MTU 9000)
// IP Header (20) + UDP Header (8) = 28 bytes overhead.
// 9000 - 28 = 8972 max théorique.
// On fixe à 8900 pour la sécurité et l'alignement.
#define MAX_UDP_PAYLOAD 8900

// En-tête spécifique pour les chunks vidéo UDP
struct UDPFrameHeader {
    uint32_t frameId;      // ID unique de la frame
    uint16_t chunkId;      // Numéro du morceau
    uint16_t totalChunks;  // Nombre total de morceaux
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;    // Taille totale de la frame décompressée
};

class NetworkSender {
private:
    int sock;
    struct sockaddr_in serverAddr;
    std::mutex sendMutex;
    uint32_t frameCounter = 0; // Pour donner un ID unique à chaque frame

public:
    // MODIFICATION: Ajout de localIp pour forcer l'interface de sortie
    NetworkSender(const std::string& destIp, int port, const std::string& localIp) {
        sock = socket(AF_INET, SOCK_DGRAM, 0); // SOCK_DGRAM pour UDP
        if (sock < 0) {
            perror("Erreur création socket UDP");
            exit(1);
        }

        // --- FIX ROUTAGE: BIND SUR L'INTERFACE THUNDERBOLT ---
        // On force le socket à utiliser l'IP locale du Mac (Thunderbolt) comme source.
        // Cela empêche l'OS de router les paquets via le Wi-Fi si les sous-réseaux se chevauchent.
        struct sockaddr_in localAddr;
        memset(&localAddr, 0, sizeof(localAddr));
        localAddr.sin_family = AF_INET;
        localAddr.sin_port = 0; // 0 = Laisse l'OS choisir un port source libre aléatoire
        if (inet_pton(AF_INET, localIp.c_str(), &localAddr.sin_addr) <= 0) {
            std::cerr << "ERREUR: IP Locale (Mac) invalide : " << localIp << std::endl;
            exit(1);
        }

        if (bind(sock, (struct sockaddr*)&localAddr, sizeof(localAddr)) < 0) {
            perror("ERREUR BIND: Impossible de s'attacher à l'IP Thunderbolt du Mac. Vérifiez l'adresse.");
            exit(1);
        }
        std::cout << "Socket lié à l'interface locale : " << localIp << std::endl;
        // -----------------------------------------------------

        // Augmentation de la taille du buffer d'envoi du socket système
        // Important pour le débit Thunderbolt
        int sendBuff = 4 * 1024 * 1024; // 4MB buffer
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sendBuff, sizeof(sendBuff));

        memset(&serverAddr, 0, sizeof(serverAddr));
        serverAddr.sin_family = AF_INET;
        serverAddr.sin_port = htons(port);
        inet_pton(AF_INET, destIp.c_str(), &serverAddr.sin_addr);
    }

    // Envoi optimisé pour les petits paquets (Souris)
    void sendMousePacket(const MousePacket& packet) {
        std::lock_guard<std::mutex> lock(sendMutex);
        // En UDP, on envoie directement sans header complexe pour la souris (latence minime)
        sendto(sock, &packet, sizeof(packet), 0, (struct sockaddr*)&serverAddr, sizeof(serverAddr));
    }

    // Envoi fragmenté pour les frames vidéo
    void sendFramePacket(const void* data, size_t size, uint16_t w, uint16_t h) {
        std::lock_guard<std::mutex> lock(sendMutex);

        frameCounter++;
        size_t totalChunks = (size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD;

        for (size_t i = 0; i < totalChunks; ++i) {
            size_t offset = i * MAX_UDP_PAYLOAD;
            size_t currentChunkSize = std::min((size_t)MAX_UDP_PAYLOAD, size - offset);

            // Construction du paquet : [UDPFrameHeader] + [Data Chunk]
            std::vector<uint8_t> packet(sizeof(UDPFrameHeader) + currentChunkSize);

            UDPFrameHeader* header = (UDPFrameHeader*)packet.data();
            header->frameId = frameCounter;
            header->chunkId = (uint16_t)i;
            header->totalChunks = (uint16_t)totalChunks;
            header->width = w;
            header->height = h;
            header->totalSize = (uint32_t)size;

            memcpy(packet.data() + sizeof(UDPFrameHeader), (uint8_t*)data + offset, currentChunkSize);

            // Envoi du chunk
            sendto(sock, packet.data(), packet.size(), 0, (struct sockaddr*)&serverAddr, sizeof(serverAddr));
        }
    }

    ~NetworkSender() {
        close(sock);
    }
};

@interface StreamOutput : NSObject <SCStreamOutput>
@property (nonatomic, assign) NetworkSender* sender;
@property (nonatomic, assign) std::vector<uint8_t>* compactBuffer;
@end

@implementation StreamOutput

- (instancetype)init {
    self = [super init];
    if (self) self.compactBuffer = new std::vector<uint8_t>();
    return self;
}

- (void)dealloc {
    delete self.compactBuffer;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !self.sender) return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    uint8_t* srcBase = (uint8_t*)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    size_t expectedSize = width * height * 4;
    size_t dstBytesPerRow = width * 4;

    if (self.compactBuffer->size() != expectedSize) {
        self.compactBuffer->resize(expectedSize);
    }
    uint8_t* dstBase = self.compactBuffer->data();

    // Copie ligne par ligne pour retirer le padding
    for (size_t y = 0; y < height; ++y) {
        memcpy(dstBase + (y * dstBytesPerRow),
               srcBase + (y * srcBytesPerRow),
               dstBytesPerRow);
    }

    // Utilisation de la méthode dédiée UDP Frame
    self.sender->sendFramePacket(dstBase, expectedSize, (uint16_t)width, (uint16_t)height);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

@end

void mouseThreadFunc(NetworkSender* sender) {
    while (true) {
        CGEventRef event = CGEventCreate(NULL);
        CGPoint cursor = CGEventGetLocation(event);
        CFRelease(event);

        MousePacket mouseData;
        mouseData.x = (int32_t)cursor.x;
        mouseData.y = (int32_t)cursor.y;

        // Utilisation de la méthode dédiée UDP Souris sur le port dédié
        sender->sendMousePacket(mouseData);

        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

int main() {
    // ---------------- CONFIGURATION IP ----------------
    // Adresse IP de la machine Linux (Destination)
    std::string linuxIP = "169.254.253.68";

    // Adresse IP de CE Mac sur l'interface Thunderbolt (Source)
    // IMPORTANT : Changez ceci par l'IP réelle de votre Mac sur le pont Thunderbolt.
    // Cela force le trafic à passer par le câble et non le Wi-Fi.
    std::string macThunderboltIP = "169.254.222.155";
    // --------------------------------------------------

    std::cout << "Initialisation UDP (Mode Thunderbolt MTU 9000)..." << std::endl;
    std::cout << "Source (Mac)      : " << macThunderboltIP << std::endl;
    std::cout << "Destination (Linux): " << linuxIP << std::endl;

    // Instance 1 : Socket Vidéo (Bind sur macIP)
    NetworkSender* videoSender = new NetworkSender(linuxIP, PORT_VIDEO, macThunderboltIP);

    // Instance 2 : Socket Souris (Bind sur macIP)
    NetworkSender* mouseSender = new NetworkSender(linuxIP, PORT_MOUSE, macThunderboltIP);

    // Lancement du thread souris avec son propre sender
    std::thread mouseThread(mouseThreadFunc, mouseSender);
    mouseThread.detach();

    std::cout << "Init ScreenCaptureKit..." << std::endl;

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) exit(1);

        SCDisplay *mainDisplay = content.displays[0];
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:mainDisplay excludingApplications:@[] exceptingWindows:@[]];

        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = mainDisplay.width;
        config.height = mainDisplay.height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.showsCursor = NO;
        config.queueDepth = 5;

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        StreamOutput *output = [[StreamOutput alloc] init];

        // On donne le sender Vidéo à l'output vidéo
        output.sender = videoSender;

        [stream addStreamOutput:output type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:nil];
        [stream startCaptureWithCompletionHandler:nil];

        std::cout << "Streaming démarré: " << mainDisplay.width << "x" << mainDisplay.height << std::endl;
    }];

    CFRunLoopRun();
    return 0;
}
