#include <algorithm>
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
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
// Appelée depuis le thread d'envoi (pas depuis main : le callback de capture
// ne fait plus que "retenir la frame", tout le travail est dans ce thread).
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

using Clock = std::chrono::steady_clock;

// ---------------------------------------------------------------------------
// Une frame NV12 vue comme deux segments mémoire (plan Y, plan UV) envoyés SANS
// copie intermédiaire : sendmsg() lit directement dans le buffer de capture.
// ---------------------------------------------------------------------------
struct FrameView {
  const uint8_t *seg[2] = {nullptr, nullptr};
  size_t len[2] = {0, 0};
  uint16_t w = 0, h = 0;
};

// ---------------------------------------------------------------------------
// Émission UDP : découpe la frame en chunks de MAX_UDP_PAYLOAD.
// ---------------------------------------------------------------------------
class NetworkSender {
private:
  int sock;
  struct sockaddr_in serverAddr;
  uint32_t frameCounter = 0;

public:
  uint64_t enobufsRetries = 0; // stats : nb de fois où la file d'interface était pleine

  NetworkSender(const std::string &destIp, int port,
                const std::string &localIp) {
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in localAddr = {0};
    localAddr.sin_family = AF_INET;
    inet_pton(AF_INET, localIp.c_str(), &localAddr.sin_addr);
    bind(sock, (struct sockaddr *)&localAddr, sizeof(localAddr));

    int sendBuff = 6 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sendBuff, sizeof(sendBuff));

    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_port = htons(port);
    inet_pton(AF_INET, destIp.c_str(), &serverAddr.sin_addr);
  }

  ~NetworkSender() { close(sock); }

  // Envoie une frame. Si `abortFlag` passe à true en cours de route (une frame
  // plus récente est arrivée), on abandonne l'envoi : utile pour les renvois
  // "keepalive" d'une image déjà périmée. Retourne false si abandonné.
  bool sendFrame(const FrameView &f, const std::atomic<bool> *abortFlag) {
    frameCounter++; // l'ID est incrémenté même pour une image identique (keepalive)

    const size_t total = f.len[0] + f.len[1];
    const size_t totalChunks = (total + MAX_UDP_PAYLOAD - 1) / MAX_UDP_PAYLOAD;

    UDPFrameHeader header;
    header.frameId = frameCounter;
    header.totalChunks = (uint16_t)totalChunks;
    header.width = f.w;
    header.height = f.h;
    header.totalSize = (uint32_t)total;

    struct iovec iov[3]; // en-tête + (fin du plan Y) + (début du plan UV)
    struct msghdr msg = {0};
    msg.msg_name = &serverAddr;
    msg.msg_namelen = sizeof(serverAddr);
    msg.msg_iov = iov;

    for (size_t i = 0; i < totalChunks; ++i) {
      if (abortFlag && abortFlag->load(std::memory_order_relaxed))
        return false;

      const size_t offset = i * MAX_UDP_PAYLOAD;
      size_t remaining = std::min((size_t)MAX_UDP_PAYLOAD, total - offset);
      header.chunkId = (uint16_t)i;

      int n = 0;
      iov[n].iov_base = &header;
      iov[n].iov_len = sizeof(UDPFrameHeader);
      n++;

      // Le chunk couvre [offset, offset+remaining) de la concaténation Y||UV :
      // on le compose avec au plus 2 morceaux (un par plan), sans copie.
      size_t pos = offset;
      for (int s = 0; s < 2 && remaining > 0; ++s) {
        const size_t segStart = (s == 0) ? 0 : f.len[0];
        const size_t segEnd = segStart + f.len[s];
        if (pos >= segEnd)
          continue;
        const size_t take = std::min(remaining, segEnd - pos);
        iov[n].iov_base = (void *)(f.seg[s] + (pos - segStart));
        iov[n].iov_len = take;
        n++;
        pos += take;
        remaining -= take;
      }
      msg.msg_iovlen = n;

      // Si la file de l'interface est pleine (ENOBUFS), on réessaie très vite :
      // elle se vide au rythme du lien. L'ancien sleep de 2 ms laissait le lien
      // inactif la majeure partie du temps. Abandon de la frame après 250 ms.
      const auto stuckSince = Clock::now();
      while (sendmsg(sock, &msg, 0) < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS) {
          enobufsRetries++;
          if (Clock::now() - stuckSince > std::chrono::milliseconds(250))
            return false;
          usleep(100);
          continue;
        }
        break; // autre erreur : on passe au chunk suivant (comme avant)
      }
    }
    return true;
  }
};

// ---------------------------------------------------------------------------
// Boîte "dernière frame gagne" (1 slot) entre le callback ScreenCaptureKit et
// le thread d'envoi. Si l'envoi est plus lent que la capture, les frames
// intermédiaires sont écrasées : on n'envoie JAMAIS une image périmée alors
// qu'une plus récente est disponible (sinon la file de SCK s'accumule en latence).
// ---------------------------------------------------------------------------
class LatestFrameSlot {
private:
  std::mutex m;
  std::condition_variable cv;
  CMSampleBufferRef pending = nullptr; // retenu (CFRetain)
  bool stopped = false;
  uint64_t dropped = 0;

public:
  std::atomic<bool> hasNew{false};

  void put(CMSampleBufferRef sb) {
    CFRetain(sb);
    CMSampleBufferRef old = nullptr;
    {
      std::lock_guard<std::mutex> lk(m);
      old = pending;
      pending = sb;
      if (old)
        dropped++;
      hasNew.store(true, std::memory_order_relaxed);
    }
    if (old)
      CFRelease(old);
    cv.notify_one();
  }

  // Attend une frame fraîche (max `timeout`). nullptr si rien. L'appelant
  // devient propriétaire de la référence retournée (doit la CFRelease).
  CMSampleBufferRef take(std::chrono::microseconds timeout) {
    std::unique_lock<std::mutex> lk(m);
    cv.wait_for(lk, timeout, [&] { return pending != nullptr || stopped; });
    CMSampleBufferRef sb = pending;
    pending = nullptr;
    hasNew.store(false, std::memory_order_relaxed);
    return sb;
  }

  uint64_t takeDropped() {
    std::lock_guard<std::mutex> lk(m);
    uint64_t d = dropped;
    dropped = 0;
    return d;
  }

  void stop() {
    {
      std::lock_guard<std::mutex> lk(m);
      stopped = true;
    }
    cv.notify_all();
  }
};

// ---------------------------------------------------------------------------
// Pompe : thread temps réel qui envoie la dernière frame capturée + renvoie la
// dernière image toutes les `keepAliveMs` si rien de neuf (reprise sur perte
// de chunk, et le receiver ne croit pas le lien mort).
// ---------------------------------------------------------------------------
class StreamPump {
private:
  NetworkSender &net;
  LatestFrameSlot slot;
  std::thread th;
  std::atomic<bool> running{true};
  std::chrono::milliseconds keepAlive;
  bool showStats;

  // âge de la capture à son arrivée dans le callback (µs) — écrit par le
  // callback, lu/remis à zéro par le thread d'envoi
  std::atomic<uint64_t> ageSumUs{0}, ageMaxUs{0}, ageN{0};

  std::vector<uint8_t> staging; // seulement si le stride n'est pas "serré"
  bool warnedStride = false;

  void transmit(CMSampleBufferRef sb, bool abortable) {
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    if (!pb)
      return;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

    const size_t width = CVPixelBufferGetWidth(pb);
    const size_t height = CVPixelBufferGetHeight(pb);
    const uint8_t *yBase =
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    const size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    const uint8_t *uvBase =
        (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    const size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    const size_t uvHeight = CVPixelBufferGetHeightOfPlane(pb, 1);

    FrameView fv;
    fv.w = (uint16_t)width;
    fv.h = (uint16_t)height;

    if (yStride == width && uvStride == width) {
      // Cas nominal : plans contigus, envoi direct SANS copie.
      fv.seg[0] = yBase;
      fv.len[0] = width * height;
      fv.seg[1] = uvBase;
      fv.len[1] = width * uvHeight;
    } else {
      // Stride avec padding : on compacte (copie) dans un tampon réutilisé.
      if (!warnedStride) {
        fprintf(stderr,
                "sender: stride Y=%zu UV=%zu != largeur %zu -> envoi avec copie\n",
                yStride, uvStride, width);
        warnedStride = true;
      }
      const size_t ySize = width * height;
      const size_t uvSize = width * uvHeight;
      if (staging.size() != ySize + uvSize)
        staging.resize(ySize + uvSize);
      for (size_t r = 0; r < height; ++r)
        memcpy(staging.data() + r * width, yBase + r * yStride, width);
      for (size_t r = 0; r < uvHeight; ++r)
        memcpy(staging.data() + ySize + r * width, uvBase + r * uvStride, width);
      fv.seg[0] = staging.data();
      fv.len[0] = ySize + uvSize;
    }

    net.sendFrame(fv, abortable ? &slot.hasNew : nullptr);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
  }

  void run() {
    setRealTimePriority();

    CMSampleBufferRef cur = nullptr; // dernière frame envoyée (pour le keepalive)
    auto lastSend = Clock::now();
    auto lastStats = Clock::now();
    uint64_t framesSent = 0, keepalives = 0;
    double sendSumMs = 0, sendMaxMs = 0;

    while (running.load()) {
      const auto sinceSend = Clock::now() - lastSend;
      std::chrono::microseconds wait = std::chrono::milliseconds(100);
      if (cur) {
        wait = std::chrono::duration_cast<std::chrono::microseconds>(
            keepAlive - sinceSend);
        if (wait < std::chrono::microseconds(200))
          wait = std::chrono::microseconds(200);
      }

      CMSampleBufferRef sb = slot.take(wait);
      if (!running.load()) {
        if (sb)
          CFRelease(sb);
        break;
      }

      if (sb) {
        if (cur)
          CFRelease(cur);
        cur = sb;
        const auto t0 = Clock::now();
        transmit(cur, /*abortable=*/false);
        const double ms =
            std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        sendSumMs += ms;
        sendMaxMs = std::max(sendMaxMs, ms);
        framesSent++;
        lastSend = Clock::now();
      } else if (cur && Clock::now() - lastSend >= keepAlive) {
        transmit(cur, /*abortable=*/true); // abandonné si une frame neuve arrive
        keepalives++;
        lastSend = Clock::now();
      }

      if (showStats && Clock::now() - lastStats >= std::chrono::seconds(1)) {
        const uint64_t n = ageN.exchange(0);
        const double ageAvg = n ? (ageSumUs.exchange(0) / 1000.0) / n : 0.0;
        const double ageMax = ageMaxUs.exchange(0) / 1000.0;
        fprintf(stderr,
                "[TX] envoyées %llu | écrasées %llu | keepalive %llu | "
                "capture->callback %.1f(%.1f) ms | envoi %.1f(%.1f) ms | "
                "ENOBUFS %llu\n",
                (unsigned long long)framesSent,
                (unsigned long long)slot.takeDropped(),
                (unsigned long long)keepalives, ageAvg, ageMax,
                framesSent ? sendSumMs / framesSent : 0.0, sendMaxMs,
                (unsigned long long)net.enobufsRetries);
        framesSent = keepalives = 0;
        sendSumMs = sendMaxMs = 0;
        net.enobufsRetries = 0;
        lastStats = Clock::now();
      }
    }

    if (cur)
      CFRelease(cur);
  }

public:
  StreamPump(NetworkSender &n, int keepAliveMs, bool stats)
      : net(n), keepAlive(std::chrono::milliseconds(keepAliveMs)),
        showStats(stats) {
    th = std::thread(&StreamPump::run, this);
  }

  ~StreamPump() {
    running = false;
    slot.stop();
    if (th.joinable())
      th.join();
  }

  // Appelé par le callback ScreenCaptureKit : retour immédiat, aucun travail lourd.
  void submit(CMSampleBufferRef sb) {
    if (showStats) {
      const CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
      const double ageMs =
          (CMTimeGetSeconds(now) -
           CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))) *
          1000.0;
      if (ageMs >= 0 && ageMs < 1000) {
        const uint64_t us = (uint64_t)(ageMs * 1000.0);
        ageSumUs.fetch_add(us, std::memory_order_relaxed);
        if (us > ageMaxUs.load(std::memory_order_relaxed))
          ageMaxUs.store(us, std::memory_order_relaxed);
        ageN.fetch_add(1, std::memory_order_relaxed);
      }
    }
    slot.put(sb);
  }
};

// StreamOutput class to handle stream output
@interface StreamOutput : NSObject <SCStreamOutput>
@property(nonatomic, assign) StreamPump *pump;
@end

@implementation StreamOutput
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type != SCStreamOutputTypeScreen || !self.pump)
    return;
  // Les frames "idle" n'ont pas d'image : rien à envoyer.
  if (!CMSampleBufferGetImageBuffer(sampleBuffer))
    return;
  self.pump->submit(sampleBuffer);
}
@end

// File dédiée au callback de capture (QoS interactif) : on ne partage plus la
// file principale avec la run loop de l'app. Le callback est quasi instantané
// (retain + échange de pointeur), le travail est dans le thread de StreamPump.
static dispatch_queue_t captureQueue() {
  static dispatch_queue_t q = nullptr;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    q = dispatch_queue_create("remotedisplay.capture", attr);
  });
  return q;
}

// Main function
// Usage : sender [--display <CGDirectDisplayID>] [--width <px>] [--height <px>]
//               [--keepalive-ms <ms>] [--stats]
//   Sans argument : capture l'écran principal à SA résolution native (pixels).
//   --display : cible un écran précis (ex. l'écran virtuel BetterDisplay).
//   --width/--height : force la résolution de capture (à éviter, casse le 1:1).
//   --keepalive-ms : renvoi de la dernière image si rien de neuf (déf. 16).
//   --stats : affiche chaque seconde des mesures d'envoi/latence sur stderr.
int main(int argc, char **argv) {
  int forcedDisplayID = -1;
  int forcedWidth = 0, forcedHeight = 0;
  int keepAliveMs = 16;
  bool showStats = false;
  for (int i = 1; i < argc; ++i) {
    if (strcmp(argv[i], "--display") == 0 && i + 1 < argc)
      forcedDisplayID = atoi(argv[++i]);
    else if (strcmp(argv[i], "--width") == 0 && i + 1 < argc)
      forcedWidth = atoi(argv[++i]);
    else if (strcmp(argv[i], "--height") == 0 && i + 1 < argc)
      forcedHeight = atoi(argv[++i]);
    else if (strcmp(argv[i], "--keepalive-ms") == 0 && i + 1 < argc)
      keepAliveMs = std::max(1, atoi(argv[++i]));
    else if (strcmp(argv[i], "--stats") == 0)
      showStats = true;
  }
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
  // Create a NetworkSender object + la pompe d'envoi (thread temps réel)
  NetworkSender *videoSender = new NetworkSender(linuxIP, PORT_VIDEO, macIP);
  StreamPump *pump = new StreamPump(*videoSender, keepAliveMs, showStats);

  // Use SCShareableContent to handle screen sharing
  // This block handles the screen sharing setup
  [SCShareableContent getShareableContentWithCompletionHandler:^(
                          SCShareableContent *content, NSError *error) {
    if (error)
      exit(1);

    // --- Sélection de l'écran cible ---
    SCDisplay *mainDisplay = content.displays.firstObject;
    if (forcedDisplayID > 0) {
      for (SCDisplay *d in content.displays) {
        if ((int)d.displayID == forcedDisplayID) {
          mainDisplay = d;
          break;
        }
      }
    }
    if (!mainDisplay)
      exit(1);

    // --- Résolution de capture ---
    // Par défaut : résolution NATIVE en pixels (backing store) du mode courant
    // de l'écran, pour une capture 1:1 sans rééchantillonnage interne à SCK.
    // Forcer 3840x2160 sur une dalle 4096x2304 / 5120x2880 -> perte de netteté.
    size_t capW = 0, capH = 0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(mainDisplay.displayID);
    if (mode) {
      capW = CGDisplayModeGetPixelWidth(mode);
      capH = CGDisplayModeGetPixelHeight(mode);
      CGDisplayModeRelease(mode);
    }
    if (forcedWidth > 0 && forcedHeight > 0) {
      capW = (size_t)forcedWidth;
      capH = (size_t)forcedHeight;
    }
    if (capW == 0 || capH == 0) { // dernier repli
      capW = 3840;
      capH = 2160;
    }
    capW &= ~((size_t)1); // NV12 exige des dimensions paires
    capH &= ~((size_t)1);

    fprintf(stderr, "Capture display %u @ %zux%zu\n",
            (unsigned)mainDisplay.displayID, capW, capH);

    SCContentFilter *filter =
        [[SCContentFilter alloc] initWithDisplay:mainDisplay
                           excludingApplications:@[]
                                exceptingWindows:@[]];
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = capW;
    config.height = capH;
    config.scalesToFit = YES;
    config.preservesAspectRatio = YES;

    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    // Display P3 = primaires P3 + blanc D65 + transfert sRGB. NE PAS utiliser
    // kCGColorSpaceDCIP3 (blanc DCI verdâtre + gamma 2.6 -> teinte verte, tons
    // sombres). Display P3 et Rec.709 partagent la matrice YCbCr (coeffs 709),
    // donc le receiver décode en BT.709 dans les deux cas ; passer à
    // kCGColorSpaceITUR_709 ici suffit pour repasser en gamut standard.
    config.colorSpaceName = kCGColorSpaceDisplayP3;

    config.minimumFrameInterval = CMTimeMake(1, 120);
    // Le callback rend la main immédiatement, donc la file SCK ne s'accumule
    // plus ; la profondeur sert juste de marge pour les 2 buffers qu'on retient
    // (slot "dernière frame" + frame gardée pour le keepalive).
    config.queueDepth = 5;

    SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:config
                                               delegate:nil];
    StreamOutput *output = [[StreamOutput alloc] init];
    output.pump = pump;
    [stream addStreamOutput:output
                       type:SCStreamOutputTypeScreen
         sampleHandlerQueue:captureQueue()
                      error:nil];
    [stream startCaptureWithCompletionHandler:nullptr];
  }];
  CFRunLoopRun();
  return 0;
}
