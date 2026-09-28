# remoteDisplay

A tool that turns an Intel iMac into an external display for another Mac, entirely in software, with no hardware modification — by streaming uncompressed 4K frames over the Thunderbolt link.

## Motivation

Pre-Retina hardware mods aside, there's no supported way to reuse an Intel iMac's 4K panel as a plain external display once the machine itself is retired — Apple's old Target Display Mode was dropped starting with the Retina iMacs, and reusing the panel otherwise means desoldering it onto a dedicated display board. remoteDisplay avoids that by using the Thunderbolt 3 link the iMac already has as a plain high-bandwidth network link, instead of any video-specific protocol.

## Why not Sunshine, VNC, or another remote-desktop tool?

Sunshine, VNC and similar tools compress frames to stay usable on a normal network link, which adds latency — noticeable enough that it doesn't feel like a real display anymore, even over a fast connection. remoteDisplay skips compression entirely and sends raw NV12 frames over the Thunderbolt link, which has the bandwidth to spare. It also drives the display *experience*, not just the video: a helper app watches the Thunderbolt connection and turns the iMac's panel on or off to follow the source Mac's state, the way a real external display would.

### Alternatives considered

- **NDI**: evaluated as the transport layer early on. Dropped — throughput and latency were far worse than a purpose-built raw UDP protocol for this use case (single point-to-point link, fixed high-bandwidth medium, no need for NDI's discovery or multi-receiver features).
- **LZ4 frame compression**: implemented and benchmarked, then reverted. The CPU cost of compressing/decompressing every frame outweighed the bandwidth it saved, and hurt latency more than it helped, given how much headroom Thunderbolt already provides.


## Architecture and Tech stack
The project is built around two main components 
- The video transmission component : Handles the heavy lifting of sending and receiving the raw video stream. 
- The command component : Orchestrate the display experience, handling commands to turn the iMac display on/off or change its brightness.

On macOS, you have the following architecture
- A helper app written in Swift 
  - A simple menubar app that monitors if the Thunderbolt link status. It automatically triggers the associated BetterDisplay virtual and starts the display streaming program
- A display streaming program written in Objective C/C++ :
  - A headless core whose sole purpose is to capture and send the display stream.
  - It captures 4K NV12 frames using Apple's native ScreenCaptureKit API

On Linux, you have the following architecture
- A helper app written in Dart (Flutter)
  - A lightweight daemon responsible for launching the the receiver program and displaying an overlay based on the commands received from the Mac. It also turns off/on the screen of the iMac.
- A video receiver program written in C++ (SDL 2):
  - A dedicated program whose sole purpose is to render the display stream on the iMac screen
  - It uses SDL2 to render the pixels on the screen and display them

Network-wise, here is the overall architecture
- Two dedicated UDP sockets, one for the video stream and another for commands system commands.
- Network Buffers on the receiver machine are changed to accommodate the large size of the uncompressed NV12 frames
- The MTU is also changed to its maximum size so the packets are not cut into multiple pieces


## Pre-requisites

- An iMac (display receiver)
  - Running Debian minimal (clean install, no desktop environment)
  - Equipped with a Thunderbolt 3 port (Thunderbolt 2 iMacs are untested)
- A Mac (emitter)
  - Running macOS 12.3 or newer
  - [BetterDisplay](https://github.com/waydabber/BetterDisplay) installed and configured with a virtual screen
  - Equipped with a Thunderbolt 3 port (again, Thunderbolt 2 is untested)
- A Thunderbolt 3/4/5 cable (20 Gbps bandwidth at minimum)

## Installation

> ⚠️ **Work in progress.** There is no one-shot installer or packaged release
> yet — the steps below are the target flow, not something you can run today.
> Until then, follow `receiver_code/README.md` and `receiver_helper/README.md`
> to build and wire things up by hand.

## On the iMac
- Make sure you have a clean install of Debian/Pop!_OS minimal on your iMac
- Type the following command
```
curl -O ...
```
- When the install finishes, reboot your iMac, the interfaces should be all correctly initialized
- The receiver helper should start automatically (as a systemd service, no desktop environment required)

## On the Mac
- Make sure your macOS version is 12.3 or newer
- Make sure the Thunderbolt Bridge interface exists in System Settings > Network Tab
- Download the .pkg installer from the Releases page
- Launch the .pkg installer and follow the steps
- Once installed, launch the app then type in the ID of the virtual display created by BetterDisplay
- You should now be able to stream the display!

# Development Setup

The project is split into independently buildable pieces:

- [`remoteDisplaySenderHelper/`](remoteDisplaySenderHelper) — the macOS side:
  Xcode project for the menubar helper (Swift) and the capture/streaming
  program (`sender.mm`, ScreenCaptureKit + UDP).
- [`receiver_code/`](receiver_code) — the Linux side: `receiver_app`, the SDL2
  / KMS-DRM display program (two threads — network and display — see its
  README to build). No Flutter/GTK dependency; build it on its own.
- [`receiver_helper/`](receiver_helper) — `rd_helper`, the headless Dart CLI
  that supervises `receiver_app` (start/stop/restart, sleep/wake, brightness)
  over UDP commands from the Mac. This is the **only** supported receiver-side
  helper — it targets a bare KMS/DRM console, no X/Wayland/desktop environment
  needed on the iMac.

# License

MIT — see [LICENSE](LICENSE).
