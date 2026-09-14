# receiver_code

Le programme d'affichage (`receiver_app`) : SDL2, KMS/DRM, deux threads
(réseau + affichage — voir l'explication détaillée du code partagée en
artifact). Build **autonome**, sans Flutter/GTK.

## Dépendances

```bash
sudo apt-get install -y build-essential cmake pkg-config libsdl2-dev
```

## Build

Via CMake (recommandé — utilisé aussi pour packager les releases) :

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/receiver_app --debug
```

Build reproductible pour déployer le binaire sur une autre machine que celle
qui compile (désactive `-march=native`) :

```bash
cmake -S . -B build -DPORTABLE=ON
```

Ou en une ligne, pour itérer vite pendant le dev :

```bash
g++ -o receiver_app receiver.cpp -lSDL2 -O3 -march=native -pthread
```

## Lancement

```bash
sudo SDL_VIDEODRIVER=kmsdrm ./receiver_app --debug
```

Nécessite `root`, ou `sudo setcap 'cap_sys_nice=eip' receiver_app` pour la
priorité temps réel (SCHED_FIFO) sans lancer en root.

Options : `--debug`, `--width <px> --height <px>` (force un mode d'affichage
précis ; sans ça, le receiver suit automatiquement la résolution du flux —
voir `TUNING.md` à la racine du dépôt).

## Utilisation normale

En pratique ce binaire n'est pas lancé à la main : c'est
[`../receiver_helper`](../receiver_helper) (le helper headless `rd_helper`)
qui le supervise — démarrage, arrêt, veille/réveil, redémarrage automatique.
