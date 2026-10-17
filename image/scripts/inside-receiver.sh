#!/usr/bin/env bash
# Runs in the linux/amd64 builder container (see build.sh): builds the pinned SDL and receiver_app.
set -euo pipefail

cd /work/image
BUILD_DIR=/var/lib/rd-build

# SDL is pinned to 2.30.0 on purpose. Debian trixie ships 2.32.4, whose KMS/DRM
# double-buffering makes the receiver skip ~5 of 60 frames per second and roughly
# doubles the wait before the vblank (measured on the reference iMac; 2.30.0 shows
# 60/60 frames). Built KMS/DRM + ALSA only: no X11, Wayland or PulseAudio.
SDL_TAG=release-2.30.0
SDL_COMMIT=859844eae358447be8d66e6da59b6fb3df0ed778
SDL_PREFIX="$BUILD_DIR/sdl-$SDL_TAG"

if [ ! -f "$SDL_PREFIX/lib/libSDL2-2.0.so.0" ]; then
    echo "==> SDL $SDL_TAG"
    rm -rf "$BUILD_DIR/sdl-src" "$BUILD_DIR/sdl-build"
    git clone --quiet --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git "$BUILD_DIR/sdl-src"
    [ "$(git -C "$BUILD_DIR/sdl-src" rev-parse HEAD)" = "$SDL_COMMIT" ] \
        || { echo "unexpected SDL commit for $SDL_TAG"; exit 1; }
    cmake -S "$BUILD_DIR/sdl-src" -B "$BUILD_DIR/sdl-build" -G "Unix Makefiles" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$SDL_PREFIX" \
        -DSDL_X11=OFF -DSDL_WAYLAND=OFF -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF \
        -DSDL_SNDIO=OFF -DSDL_KMSDRM=ON -DSDL_KMSDRM_SHARED=ON -DSDL_OPENGL=ON -DSDL_OPENGLES=ON \
        -DSDL_TESTS=OFF -DSDL_INSTALL_TESTS=OFF >/dev/null
    cmake --build "$BUILD_DIR/sdl-build" -j"$(nproc)" >/dev/null
    cmake --install "$BUILD_DIR/sdl-build" >/dev/null
fi

# PORTABLE=ON: no -march=native, the binary must run on every supported iMac.
echo "==> receiver_app"
rm -rf "$BUILD_DIR/receiver-sdl"
PKG_CONFIG_PATH="$SDL_PREFIX/lib/pkgconfig" cmake -S ../receiver_code -B "$BUILD_DIR/receiver-sdl" \
    -DCMAKE_BUILD_TYPE=Release -DPORTABLE=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath,/opt/remotedisplay/lib"
cmake --build "$BUILD_DIR/receiver-sdl" -j"$(nproc)"
install -Dm755 "$BUILD_DIR/receiver-sdl/receiver_app" payload/opt/remotedisplay/receiver_app
rm -rf payload/opt/remotedisplay/lib && mkdir -p payload/opt/remotedisplay/lib
cp -a "$SDL_PREFIX"/lib/libSDL2-2.0.so* payload/opt/remotedisplay/lib/
ldd payload/opt/remotedisplay/receiver_app | grep -E "SDL2" || true
