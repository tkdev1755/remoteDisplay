#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <mutex>
#include <sys/socket.h>
#include <sys/uio.h>
#include <thread>
#include <unistd.h>
#include <vector>

#import <ApplicationServices/ApplicationServices.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>

#define PORT_VIDEO 5000
#define MAX_UDP_PAYLOAD 65000

struct UDPFrameHeader {
  // Frame Identifier - Unique ID for each frame
  uint32_t frameId;
  // Chunk Identifier - Used to segment the frame data
  uint16_t chunkId;
  // Total Number of Chunks in this Frame
  uint16_t totalChunks;
  // Frame Width
  uint16_t width;
  // Frame Height
  uint16_t height;
  // Total Size of the Frame Data
  uint32_t totalSize;
};

// Sets the thread time constraint policy to prioritize real-time processing.
// This ensures that the sender thread receives sufficient CPU time to handle
// incoming frames promptly.
void setRealTimePriority() {
  thread_time_constraint_policy_data_t policy;
  policy.period = 0;
  policy.computation = 50000;
  policy.constraint = 80000;
  policy.preemptible = 0;
  thread_policy_set(mach_thread_self(), THREAD_TIME_CONSTRAINT_POLICY,
                    (thread_policy_t)&policy,
                    THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}
// Class to handle sending video frames over UDP

class NetworkSender {
private:
  // Socket descriptor for UDP communication
  int sock;
  // Structure to store server address information
  struct sockaddr_in serverAddr;
  // Mutex to protect shared resources (e.g., frame data, sendMutex)
  std::mutex sendMutex;
  // Frame counter to generate unique IDs for each frame
  uint32_t frameCounter = 0;

  // Stores the last captured frame data
  std::vector<uint8_t> lastFrameData;
  // Stores the last width and height of the frame
  uint16_t lastW = 0, lastH = 0;
  // Time of the last send operation
  std::chrono::steady_clock::time_point lastSendTime;
  // Atomic boolean to control the sender thread's running state
  std::atomic<bool> running{true};
  // Thread to keep the sender loop running
  std::thread keepAliveThread;

public:
  // Constructor for the NetworkSender class
  // Takes the destination IP address, port number, and local IP address as
  // arguments
  NetworkSender(const std::string &destIp, int port,
                const std::string &localIp) {
    // Create a UDP socket
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    // Initialize the server address structure
    struct sockaddr_in localAddr = {0};
    localAddr.sin_family = AF_INET;
    // Convert the local IP address from string to binary format
    inet_pton(AF_INET, localIp.c_str(), &localAddr.sin_addr);
    // Bind the socket to the local address
    bind(sock, (struct sockaddr *)&localAddr, sizeof(localAddr));

    // Set the send buffer size to 6MB
    int sendBuff = 6 * 1024 * 1024;
    // Set the socket option for the send buffer size
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sendBuff, sizeof(sendBuff));

    // Initialize the server address structure
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(port);
    // Convert the destination IP address from string to binary format
    inet_pton(AF_INET, destIp.c_str(), &serverAddr.sin_addr);

    // Record the time of the last send operation
    lastSendTime = std::chrono::steady_clock::now();

    // Start the keepAliveLoop thread
    keepAliveThread = std::thread(&NetworkSender::keepAliveLoop, this);
  }

  // Function to implement the keepAliveLoop thread
  void keepAliveLoop() {
    // Loop indefinitely until the running flag is set to false
    while (running) {
      // Sleep for 8 milliseconds
      std::this_thread::sleep_for(std::chrono::milliseconds(8));

      // Get the current time
      auto now = std::chrono::steady_clock::now();
      // Acquire a lock on the sendMutex
      std::lock_guard<std::mutex> lock(sendMutex);

      // Check if a sufficient time has passed since the last send operation
      if (std::chrono::duration_cast<std::chrono::milliseconds>(now -
                                                                lastSendTime)
                  .count() > 16 &&
          !lastFrameData.empty()) {
        // Send the frame packet
        sendFramePacketInternal(lastFrameData.data(), lastFrameData.size(),
                                lastW, lastH);
      }
    }
  }
  // Function to send a frame packet
  void sendFramePacket(const void *data, size_t size, uint16_t w, uint16_t h) {
    {
      // Acquire a lock on the sendMutex
      std::lock_guard<std::mutex> lock(sendMutex);

      // Check if the lastFrameData vector is large enough to hold the new data
      if (lastFrameData.size() != size)
        lastFrameData.resize(size);
      // Copy the data into the lastFrameData vector
      memcpy(lastFrameData.data(), data,
             size); // Update the last width and height
      lastW = w;
      lastH = h;
    }
    // Call the sendFramePacketInternal function
    sendFramePacketInternal(data, size, w, h);
  }

private:
  // Function to send the actual frame packet
  void sendFramePacketInternal(const void *data, size_t size, uint16_t w,
                               uint16_t h) {
    // Increment the frame counter
    frameCounter++; // ID is always incremented, even for the same frame
    // Record the time of the last send operation
    lastSendTime = std::chrono::steady_clock::now();

    // Calculate the total number of chunks in the frame
    size_t totalChunks = (size + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD;
    // Create a UDP frame header
    UDPFrameHeader header;
    header.frameId = frameCounter;
    // Set the total number of chunks
    header.totalChunks = (uint16_t)totalChunks;
    // Set the width and height
    header.width = w;
    header.height = h;
    header.totalSize = (uint32_t)size;

    // Create a message header
    struct msghdr msg = {0};
    struct iovec iov[2];
    // Initialize the message header
    msg.msg_name = &serverAddr;
    msg.msg_namelen = sizeof(serverAddr);
    // Create an Iovec structure
    msg.msg_iov = iov;
    msg.msg_iovlen = 2;

    uint8_t *byteData = (uint8_t *)data;

    // Loops to send all chunks to the receiver
    for (size_t i = 0; i < totalChunks; ++i) {

      size_t offset = i * MAX_UDP_PAYLOAD;
      size_t currentChunkSize =
          std::min((size_t)MAX_UDP_PAYLOAD, size - offset);
      header.chunkId = (uint16_t)i;
      iov[0].iov_base = &header;
      iov[0].iov_len = sizeof(UDPFrameHeader);
      iov[1].iov_base = byteData + offset;
      iov[1].iov_len = currentChunkSize;

      if (sendmsg(sock, &msg, 0) < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) {
          // Handle errors (e.g., sleep for a short time)
          std::this_thread::sleep_for(
              std::chrono::milliseconds(2)); // Laisse macOS vider le buffer !
          i--;
          continue;
        }
      }
    }
  }

public:
  // Destructor for the NetworkSender class
  // Terminates the keepAliveThread and closes the socket
  ~NetworkSender() {
    running = false;
    if (keepAliveThread.joinable())
      keepAliveThread.join();
    close(sock);
  }
};
// StreamOutput class to handle stream output
@interface StreamOutput : NSObject <SCStreamOutput>
@property(nonatomic, assign) NetworkSender *sender;
@property(nonatomic, assign) std::vector<uint8_t> *nv12Buffer;
@end

@implementation StreamOutput
- (instancetype)init {
  self = [super init];
  if (self)
    self.nv12Buffer = new std::vector<uint8_t>();
  return self;
}
- (void)dealloc {
  delete self.nv12Buffer;
  [super dealloc];
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || !self.sender)
    return;
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!pixelBuffer)
    return;
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);
  uint8_t *yBase =
      (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
  size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  uint8_t *uvBase =
      (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
  size_t uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  size_t uvPlaneHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

  size_t totalSize = (width * height) + (width * height / 2);
  if (self.nv12Buffer->size() != totalSize)
    self.nv12Buffer->resize(totalSize);
  uint8_t *dst = self.nv12Buffer->data();

  if (yBytesPerRow == width)
    memcpy(dst, yBase, width * height);
  else
    for (size_t i = 0; i < height; ++i)
      memcpy(dst + (i * width), yBase + (i * yBytesPerRow), width);

  uint8_t *dstUV = dst + (width * height);
  if (uvBytesPerRow == width)
    memcpy(dstUV, uvBase, width * uvPlaneHeight);
  else
    for (size_t i = 0; i < uvPlaneHeight; ++i)
      memcpy(dstUV + (i * width), uvBase + (i * uvBytesPerRow), width);

  self.sender->sendFramePacket(dst, totalSize, (uint16_t)width,
                               (uint16_t)height);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}
@end

// Main function
int main() {
  // Set the thread time constraint policy to prioritize real-time processing
  setRealTimePriority();
  // Get the process information
  NSProcessInfo *processInfo = [NSProcessInfo processInfo];
  // Begin the activity with user-initiated and latency-critical options
  [processInfo beginActivityWithOptions:NSActivityUserInitiated |
                                        NSActivityLatencyCritical
                                 reason:@"Thunderbolt Stream"];

  // Define the IP addresses
  std::string linuxIP = "10.0.0.1";
  std::string macIP = "10.0.0.2";

  // Print a message to the console
  std::cout << "Now streaming to " << linuxIP << "..." << std::endl;
  // Create a NetworkSender object
  NetworkSender *videoSender = new NetworkSender(linuxIP, PORT_VIDEO, macIP);

  // Use SCShareableContent to handle screen sharing
  // This block handles the screen sharing setup
  [SCShareableContent getShareableContentWithCompletionHandler:^(
                          SCShareableContent *content, NSError *error) {
    if (error)
      exit(1);
    SCDisplay *mainDisplay = content.displays[0];
    SCContentFilter *filter =
        [[SCContentFilter alloc] initWithDisplay:mainDisplay
                           excludingApplications:@[]
                                exceptingWindows:@[]];
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = 3840;
    config.height = 2160;
    config.scalesToFit = YES;
    config.preservesAspectRatio = YES;

    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    config.colorSpaceName = kCGColorSpaceDCIP3;

    config.minimumFrameInterval = CMTimeMake(1, 120);
    config.queueDepth = 5;

    SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:config
                                               delegate:nil];
    StreamOutput *output = [[StreamOutput alloc] init];
    output.sender = videoSender;
    [stream addStreamOutput:output
                       type:SCStreamOutputTypeScreen
         sampleHandlerQueue:dispatch_get_main_queue()
                      error:nil];
    [stream startCaptureWithCompletionHandler:nullptr];
  }];
  CFRunLoopRun();
  return 0;
}
