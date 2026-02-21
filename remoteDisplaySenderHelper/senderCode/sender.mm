/*
 * MAC SENDER (Objective-C++) - CONSTANT 60 FPS FORCER
 * Feature: "Keep-Alive" Thread. Sends duplicate frames if macOS sleeps.
 * Result: Zero latency on wake-up.
 */

#include <iostream>
#include <vector>
#include <thread>
#include <atomic>
#include <chrono>
#include <mutex>
#include <cmath>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/uio.h>

#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ApplicationServices/ApplicationServices.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>

#define PORT_VIDEO 5000
#define MAX_UDP_PAYLOAD 65000

struct UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

void setRealTimePriority() {
    thread_time_constraint_policy_data_t policy;
    policy.period = 0; policy.computation = 50000; policy.constraint = 80000; policy.preemptible = 0;
    thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

class NetworkSender {
private:
    int sock;
    struct sockaddr_in serverAddr;
    std::mutex sendMutex;
    uint32_t frameCounter = 0;

    // --- SYSTEME DE RÉPÉTITION (KEEP ALIVE) ---
    std::vector<uint8_t> lastFrameData; // Stocke la dernière image
    uint16_t lastW = 0, lastH = 0;
    std::chrono::steady_clock::time_point lastSendTime;
    std::atomic<bool> running{true};
    std::thread keepAliveThread;
    // ------------------------------------------

public:
    NetworkSender(const std::string& destIp, int port, const std::string& localIp) {
        sock = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in localAddr = {0}; localAddr.sin_family = AF_INET;
        inet_pton(AF_INET, localIp.c_str(), &localAddr.sin_addr);
        bind(sock, (struct sockaddr*)&localAddr, sizeof(localAddr));

        int sendBuff = 4 * 1024 * 1024;
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sendBuff, sizeof(sendBuff));

        memset(&serverAddr, 0, sizeof(serverAddr));
        serverAddr.sin_family = AF_INET; serverAddr.sin_port = htons(port);
        inet_pton(AF_INET, destIp.c_str(), &serverAddr.sin_addr);

        lastSendTime = std::chrono::steady_clock::now();

        // Lancement du Thread "Métronome"
        keepAliveThread = std::thread(&NetworkSender::keepAliveLoop, this);
    }

    // Boucle qui tourne en tâche de fond pour garantir 60 FPS
    void keepAliveLoop() {
        while (running) {
            // On vise 60 FPS -> 16.66ms
            std::this_thread::sleep_for(std::chrono::milliseconds(1)); // Check fréquent

            auto now = std::chrono::steady_clock::now();
            std::lock_guard<std::mutex> lock(sendMutex);

            // Si ça fait plus de 17ms qu'on n'a rien envoyé (macOS dort)
            // ET qu'on a déjà une image en stock
            if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastSendTime).count() > 16 && !lastFrameData.empty()) {

                // ON RENVOIE LA MÊME IMAGE (DUPLICATE)
                // Cela force le tuyau à rester plein et le Receiver à rester alerte.
                sendFramePacketInternal(lastFrameData.data(), lastFrameData.size(), lastW, lastH);
            }
        }
    }

    // Fonction publique appelée par ScreenCaptureKit (Nouvelle image réelle)
    void sendFramePacket(const void* data, size_t size, uint16_t w, uint16_t h) {
        std::lock_guard<std::mutex> lock(sendMutex);

        // On sauvegarde cette image pour le mode "Keep Alive"
        if (lastFrameData.size() != size) lastFrameData.resize(size);
        memcpy(lastFrameData.data(), data, size);
        lastW = w;
        lastH = h;

        sendFramePacketInternal(data, size, w, h);
    }

private:
    // Fonction interne d'envoi (Déjà lockée par le Mutex)
    void sendFramePacketInternal(const void* data, size_t size, uint16_t w, uint16_t h) {
        frameCounter++; // On incrémente TOUJOURS l'ID, même pour une frame dupliquée
        lastSendTime = std::chrono::steady_clock::now();

        size_t totalChunks = (size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD;
        UDPFrameHeader header;
        header.frameId = frameCounter;
        header.totalChunks = (uint16_t)totalChunks;
        header.width = w; header.height = h; header.totalSize = (uint32_t)size;

        struct msghdr msg = {0}; struct iovec iov[2];
        msg.msg_name = &serverAddr; msg.msg_namelen = sizeof(serverAddr);
        msg.msg_iov = iov; msg.msg_iovlen = 2;

        uint8_t* byteData = (uint8_t*)data;

        for (size_t i = 0; i < totalChunks; ++i) {
            size_t offset = i * MAX_UDP_PAYLOAD;
            size_t currentChunkSize = std::min((size_t)MAX_UDP_PAYLOAD, size - offset);
            header.chunkId = (uint16_t)i;
            iov[0].iov_base = &header; iov[0].iov_len = sizeof(UDPFrameHeader);
            iov[1].iov_base = byteData + offset; iov[1].iov_len = currentChunkSize;

            if (sendmsg(sock, &msg, 0) < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) {
                    usleep(1); i--; continue;
                }
            }
        }
    }

public:
    ~NetworkSender() {
        running = false;
        if (keepAliveThread.joinable()) keepAliveThread.join();
        close(sock);
    }
};

@interface StreamOutput : NSObject <SCStreamOutput>
@property (nonatomic, assign) NetworkSender* sender;
@property (nonatomic, assign) std::vector<uint8_t>* nv12Buffer;
@end

@implementation StreamOutput
- (instancetype)init { self = [super init]; if (self) self.nv12Buffer = new std::vector<uint8_t>(); return self; }
- (void)dealloc { delete self.nv12Buffer; [super dealloc]; }

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !self.sender) return;
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    uint8_t* yBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    uint8_t* uvBase = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    size_t uvPlaneHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

    size_t totalSize = (width * height) + (width * height / 2);
    if (self.nv12Buffer->size() != totalSize) self.nv12Buffer->resize(totalSize);
    uint8_t* dst = self.nv12Buffer->data();

    if (yBytesPerRow == width) memcpy(dst, yBase, width * height);
    else for (size_t i = 0; i < height; ++i) memcpy(dst + (i * width), yBase + (i * yBytesPerRow), width);

    uint8_t* dstUV = dst + (width * height);
    if (uvBytesPerRow == width) memcpy(dstUV, uvBase, width * uvPlaneHeight);
    else for (size_t i = 0; i < uvPlaneHeight; ++i) memcpy(dstUV + (i * width), uvBase + (i * uvBytesPerRow), width);

    self.sender->sendFramePacket(dst, totalSize, (uint16_t)width, (uint16_t)height);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

int main() {
    setRealTimePriority();
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    [processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"Thunderbolt Stream"];

    // CONFIG IP
    std::string linuxIP = "10.0.0.1";
    std::string macIP = "10.0.0.2";

    std::cout << "Streaming CONSTANT 60 FPS (Keep-Alive Mode) to " << linuxIP << "..." << std::endl;
    NetworkSender* videoSender = new NetworkSender(linuxIP, PORT_VIDEO, macIP);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) exit(1);
        SCDisplay *mainDisplay = content.displays[0];
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:mainDisplay excludingApplications:@[] exceptingWindows:@[]];
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = 3840; config.height = 2160;
        config.scalesToFit = YES; config.preservesAspectRatio = YES;

        // Retour au P3 pour performance native maximale
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        config.colorSpaceName = kCGColorSpaceDisplayP3;

        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.queueDepth = 3; // On peut remettre un peu de buffer car le KeepAlive gère la fluidité

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        StreamOutput *output = [[StreamOutput alloc] init];
        output.sender = videoSender;
        [stream addStreamOutput:output type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:nil];
        [stream startCaptureWithCompletionHandler:nil];
    }];
    CFRunLoopRun();
    return 0;
}
