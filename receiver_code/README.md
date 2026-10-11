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

## Latence : flags et mesures

| Flag | Effet |
|---|---|
| *(défaut)* | double buffering KMS + late-latch (voir ci-dessous) |
| `--no-latelatch` | désactive le pacing late-latch (retour au « présente dès que prêt ») |
| `--triple-buffer` | retour au triple buffering par défaut de SDL (+1 frame de latence) |

- **Double buffering** : `SDL_VIDEO_DOUBLE_BUFFER=1` — SDL attend le vblank
  juste après avoir posté le flip au lieu de laisser une 3ᵉ image en file.
- **Late-latch** : le thread d'affichage dort jusqu'à *(prochain vblank − budget)*
  puis prend la frame la plus fraîche, la rend et la présente juste à temps. Le
  budget (durée de rendu + marge) s'auto-ajuste ; si `RenderPresent` ne bloque
  pas sur le vblank, le mécanisme se désactive tout seul (log `⚠️`).
- **`MSG_WAITFORONE`** sur `recvmmsg` : sans lui, la fin d'une frame restait
  coincée jusqu'à l'arrivée de la suivante.

Avec `--debug`, une ligne par seconde décompose où part le temps (ms, moyenne
et max entre parenthèses) :

```
[LAT ms moy(max)] réseau 8.9(9.4) | boîte 3.1(7.9) | rendu 2.6(3.0) | vblank 2.1(2.4) | TOTAL 16.7(21.0) | budget 4.7
```

- **réseau** : 1ᵉʳ chunk reçu → frame complète (temps de transmission + réassemblage)
- **boîte** : frame complète → prise par le thread d'affichage
- **rendu** : upload texture + rendu CPU
- **vblank** : attente du flip (≈ la marge laissée par le late-latch)
- **TOTAL** : 1ᵉʳ chunk reçu → flip effectué. C'est la latence côté receiver,
  hors capture et hors balayage de la dalle (~16 ms du haut au bas, incompressible).

## Utilisation normale

En pratique ce binaire n'est pas lancé à la main : c'est
[`../receiver_helper`](../receiver_helper) (le helper headless `rd_helper`)
qui le supervise — démarrage, arrêt, veille/réveil, redémarrage automatique.
