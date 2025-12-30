#ifndef COMMON_H
#define COMMON_H

#include <cstdint>

const int PORT = 9999;
const uint32_t PACKET_MAGIC = 0xDEADBEEF; // Marqueur de début de paquet

enum class PacketType : uint8_t {
    FRAME_DATA = 1,
    MOUSE_POS = 2
};

struct PacketHeader {
    uint32_t magic;      // DOIT être 0xDEADBEEF
    PacketType type;
    uint32_t payloadSize;
    uint16_t width;
    uint16_t height;
} __attribute__((packed));

struct MousePacket {
    int32_t x;
    int32_t y;
} __attribute__((packed));

#endif
