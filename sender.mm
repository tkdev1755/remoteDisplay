/*
 * MAC SENDER (Objective-C++) - FINAL GOLD VERSION
 * Optimisations: MTU 65k, Pacer V2, Color Correction, Mach RealTime
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

// MACH (Priorité CPU)
#include <mach/mach.h>
#include <mach/thread_policy.h>

#define PORT_VIDEO 5000
// Optimisation MTU 65518 : On envoie des paquets géants (moins d'interruptions CPU)
#define MAX_UDP_PAYLOAD 65000

struct UDPFrameHeader {
    uint32_t frameId;
    uint16_t chunkId;
    uint16_t totalChunks;
    uint16_t width;
    uint16_t height;
    uint32_t totalSize;
};

// Fonction pour passer le thread en priorité "Temps Réel" au niveau du Kernel Mach
void setRealTimePriority() {
    thread_time_constraint_policy_data_t policy;
    policy.period = 0;
    policy.computation = 50000;
    policy.constraint = 80000;
    policy.preemptible = 0;

    kern_return_t ret = thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (ret == KERN_SUCCESS) std::cout << "⚡ Priorité Mach RealTime activée." << std::endl;
}

class NetworkSender {
private:
    int sock;
    struct sockaddr_in serverAddr;
    std::mutex sendMutex;
    uint32_t frameCounter = 0;

public:
    NetworkSender(const std::string& destIp, int port, const std::string& localIp) {
        sock = socket(AF_INET, SOCK_DGRAM, 0);

        struct sockaddr_in localAddr = {0};
        localAddr.sin_family = AF_INET;
        inet_pton(AF_INET, localIp.c_str(), &localAddr.sin_addr);
        bind(sock, (struct sockaddr*)&localAddr, sizeof(localAddr));

        // Buffer d'envoi 4MB
        int sendBuff = 4 * 1024 * 1024;
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sendBuff, sizeof(sendBuff));

        memset(&serverAddr, 0, sizeof(serverAddr));
        serverAddr.sin_family = AF_INET;
        serverAddr.sin_port = htons(port);
        inet_pton(AF_INET, destIp.c_str(), &serverAddr.sin_addr);
    }

    void sendFramePacket(const void* data, size_t size, uint16_t w, uint16_t h) {
        std::lock_guard<std::mutex> lock(sendMutex);
        frameCounter++;
        size_t totalChunks = (size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD;

        UDPFrameHeader header;
        header.frameId = frameCounter;
        header.totalChunks = (uint16_t)totalChunks;
        header.width = w;
        header.height = h;
        header.totalSize = (uint32_t)size;

        struct msghdr msg = {0};
        struct iovec iov[2];
        msg.msg_name = &serverAddr;
        msg.msg_namelen = sizeof(serverAddr);
        msg.msg_iov = iov;
        msg.msg_iovlen = 2;

        uint8_t* byteData = (uint8_t*)data;
        int packetsBatchCount = 0;

        for (size_t i = 0; i < totalChunks; ++i) {
            size_t offset = i * MAX_UDP_PAYLOAD;
            size_t currentChunkSize = std::min((size_t)MAX_UDP_PAYLOAD, size - offset);

            header.chunkId = (uint16_t)i;

            iov[0].iov_base = &header;
            iov[0].iov_len = sizeof(UDPFrameHeader);
            iov[1].iov_base = byteData + offset;
            iov[1].iov_len = currentChunkSize;

            if (sendmsg(sock, &msg, 0) < 0) {
                // Si buffer plein, petite pause d'urgence
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) {
                    usleep(50);
                    i--; // Retry
                    continue;
                }
            }
            packetsBatchCount++;
            if (packetsBatchCount >= 4) {
                usleep(1);
                packetsBatchCount = 0;
            }
        }
    }

    ~NetworkSender() { close(sock); }
};

@interface StreamOutput : NSObject <SCStreamOutput>
@property (nonatomic, assign) NetworkSender* sender;
@property (nonatomic, assign) std::vector<uint8_t>* nv12Buffer;
@end

@implementation StreamOutput

- (instancetype)init {
    self = [super init];
    if (self) self.nv12Buffer = new std::vector<uint8_t>();
    return self;
}
- (void)dealloc {
    delete self.nv12Buffer;
    [super dealloc];
}

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

    if (self.nv12Buffer->size() != totalSize) {
        self.nv12Buffer->resize(totalSize);
    }

    uint8_t* dst = self.nv12Buffer->data();

    // Copie Y
    if (yBytesPerRow == width) {
        memcpy(dst, yBase, width * height);
    } else {
        for (size_t i = 0; i < height; ++i) {
            memcpy(dst + (i * width), yBase + (i * yBytesPerRow), width);
        }
    }

    // Copie UV (Compactage)
    uint8_t* dstUV = dst + (width * height);
    if (uvBytesPerRow == width) {
        memcpy(dstUV, uvBase, width * uvPlaneHeight);
    } else {
        for (size_t i = 0; i < uvPlaneHeight; ++i) {
            memcpy(dstUV + (i * width), uvBase + (i * uvBytesPerRow), width);
        }
    }

    self.sender->sendFramePacket(dst, totalSize, (uint16_t)width, (uint16_t)height);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

int main() {
    setRealTimePriority(); // Boost Process

    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    [processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"Thunderbolt Stream"];

    // CONFIG IP
    std::string linuxIP = "10.0.0.1";
    std::string macIP = "10.0.0.2";

    std::cout << "Streaming (MTU 65k Mode) to " << linuxIP << "..." << std::endl;

    NetworkSender* videoSender = new NetworkSender(linuxIP, PORT_VIDEO, macIP);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        if (error) exit(1);
        SCDisplay *mainDisplay = content.displays[0];
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:mainDisplay excludingApplications:@[] exceptingWindows:@[]];

        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = 3840;
        config.height = 2160;
        config.scalesToFit = YES;
        config.preservesAspectRatio = YES;

        // --- CORRECTION COULEURS ---
        // VideoRange : Évite les contrastes explosés (16-235)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        // GenericRGB : Calme la saturation par rapport au P3 natif
        config.colorSpaceName = kCGColorSpaceDisplayP3;



        config.minimumFrameInterval = CMTimeMake(1, 60);
        config.queueDepth = 3;

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        StreamOutput *output = [[StreamOutput alloc] init];
        output.sender = videoSender;

        [stream addStreamOutput:output type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_get_main_queue() error:nil];
        [stream startCaptureWithCompletionHandler:nil];
    }];

    CFRunLoopRun();
    return 0;
}
