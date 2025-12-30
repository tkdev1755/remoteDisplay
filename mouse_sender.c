/*
 * mouse_sender_hack.c
 * Compile: clang -framework ApplicationServices -framework CoreFoundation -o mouse_sender_hack mouse_sender_hack.c
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <signal.h>

// --- API PRIVÉES APPLE (Undocumented) ---
// Ces fonctions permettent de passer outre les restrictions de premier plan
typedef int CGSConnectionID;
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID targetCID, CFStringRef key, CFTypeRef value);
extern CGError CGSShowCursor(CGSConnectionID cid);
extern CGError CGSHideCursor(CGSConnectionID cid);

#define DEST_IP "169.254.X.X" // <-- Mets ton IP ici
#define DEST_PORT 9000

int sock_fd;
struct sockaddr_in dest_addr;

typedef struct __attribute__((packed)) {
    uint16_t x;
    uint16_t y;
    uint8_t  flags;
} MousePacket;

void restore_cursor(int sig) {
    // Restaure le curseur via l'API privée
    CGSShowCursor(_CGSDefaultConnection());
    if (sock_fd >= 0) close(sock_fd);
    printf("\nCurseur restauré.\n");
    exit(0);
}

CGEventRef eventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout) {
        CGEventTapEnable(proxy, true);
        return event;
    }

    CGPoint location = CGEventGetLocation(event);
    MousePacket packet;
    packet.x = htons((uint16_t)location.x);
    packet.y = htons((uint16_t)location.y);
    packet.flags = 0;
    sendto(sock_fd, &packet, sizeof(packet), 0, (struct sockaddr *)&dest_addr, sizeof(dest_addr));
    return event;
}

int main(void) {
    signal(SIGINT, restore_cursor);
    signal(SIGTERM, restore_cursor);

    printf("Target: %s:%d\n", DEST_IP, DEST_PORT);

    // 1. Initialisation Réseau
    if ((sock_fd = socket(AF_INET, SOCK_DGRAM, 0)) < 0) return 1;
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(DEST_PORT);
    inet_pton(AF_INET, DEST_IP, &dest_addr.sin_addr);

    // 2. LE HACK : Autoriser la modification du curseur en arrière-plan
    CGSConnectionID cid = _CGSDefaultConnection();
    CFStringRef key = CFSTR("SetsCursorInBackground");
    CGSSetConnectionProperty(cid, cid, key, kCFBooleanTrue);

    // 3. Masquer le curseur globalement
    CGSHideCursor(cid);
    printf("Curseur masqué via Private API (Ctrl+C pour restaurer)\n");

    // 4. Hook Event Loop
    CGEventMask eventMask = CGEventMaskBit(kCGEventMouseMoved) |
                            CGEventMaskBit(kCGEventLeftMouseDragged) |
                            CGEventMaskBit(kCGEventRightMouseDragged);
    CFMachPortRef eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, eventMask, eventCallback, NULL);

    if (!eventTap) {
        fprintf(stderr, "Erreur: Droits accessibilité manquants.\n");
        restore_cursor(0);
        return 1;
    }

    CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
    CGEventTapEnable(eventTap, true);

    CFRunLoopRun();
    return 0;
}
