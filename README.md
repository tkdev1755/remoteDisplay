# remoteDisplay
This is a tool to fully transform your Intel iMac as a display, entirely via software and with no hardware modifications.

## Motivation
The primary motivation for this project was to re-use olds iMac by repurposing their 4K retina dispalys without the need for hardware modifications. Traditionally, transforming them as a displays needed to disassemble them and using a specialized display board. remoteDisplay removes this constraint by using the bandwith of the Thunderbolt 3 link present on these machines.

## What's the difference between Sunshine, VNC or other tools ?
Sunshine or VNC rely on compression to avoid frame drops and bad performance. This generally add latency and makes it not usable even on a high bandwith link. remoteDisplay aims to supress that overhead by sending uncompressed frames on the Thunderbolt link. Furthermore, remoteDisplay is designed to replicate a display experience, by running a helper program, which is designed to detect when you connect the iMac through Thunderbolt, and turns off or turns on the iMac's Display based on the mac status.


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


# Pre-requisites 
- An iMac (Display receiver)
  - Running Debian Minimal (Clean install without a desktop environment)
  - Equipped with a Thunderbolt 3 port (iMacs with a Thunderbolt 2 port have not been tested)
- A Mac (Emitter)
  - Running MacOS 12.3 or newer
  - Having BetterDisplay installed and configured with a Virtual Screen
  - Equipped with a Thunderbolt 3 port (Again, models with a thunderbolt 2 port weren't tested)
- A Thunderbolt 3/4/5 Cable (20Gbps bandwith at minimum)

# Installation

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
## On the Mac ()
- Make sure your macOS version is superior to macOS 12.3
- Make sure the Thunderbolt Bridge interface exists in System Settings > Network Tab
- Download the .pkg installer from the Releases page
- Launch the .pkg installer and follow the steps
- Once installed, launch the app then type in the ID of the virtual display created by BetterDisplay
- You should be now able to stream the display !


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
- `TUNING.md` (gitignored, kept locally) documents every tunable parameter in
  the pipeline — buffer sizes, fps, thread priorities — and the effect of
  changing each one.

Both `receiver_code` and `receiver_helper` are meant to be **built on a dev
machine and deployed as prebuilt binaries** — the target iMac doesn't need a
C++ toolchain or the Dart SDK installed.
