# rd_helper — helper headless du récepteur

Remplaçant du helper Flutter (`receiver_helper/`) pour la configuration
**KMS/DRM sans serveur X** : le helper Flutter est une application GTK et ne peut
pas tourner sans X/Wayland.

## Ce qu'il fait (parité avec le helper Flutter, hors overlay visuel)

| Fonction | Helper Flutter | `rd_helper` |
|---|---|---|
| Lance / arrête / suspend / reprend le process `receiver_app` | ✅ | ✅ (+ redémarrage auto si crash) |
| Écoute UDP `:5002` : `SLP_DETECTED`, `CONN_OK`, `BRIGHTNESS:<n>` | ✅ | ✅ |
| Extinction écran | `xrandr --output eDP --off` | arrêt du receiver + `echo 4 > fbN/blank` (DPMS off réel) |
| Rallumage écran | `xrandr --output eDP --auto` | `echo 0 > fbN/blank` + relance du receiver + luminosité réappliquée |
| Luminosité | `brightnessctl` | `brightnessctl`, repli `/sys/class/backlight` |
| Overlay visuel (statut / barre luminosité) | fenêtre GTK transparente | ❌ *(phase 2 : rendu dans le receiver SDL)* |

## Build

Sur la machine réceptrice (Linux), SDK Dart requis :

```bash
./build.sh          # -> ./rd_helper (binaire natif autonome)
```

## Utilisation

```bash
sudo SDL_VIDEODRIVER=kmsdrm ./rd_helper --receiver /chemin/vers/receiver_app
```

Options : `--receiver <path>`, `--port <n>` (déf. 5002), `--no-debug`,
`-- <args>` transmis tels quels au receiver (ex. `-- --width 3840 --height 2160`).

Résolution auto du binaire receiver si `--receiver` absent : `$RD_RECEIVER_BIN`,
puis à côté de `rd_helper`, puis `/opt/remotedisplay/`, `/opt/receiver_helper/data/bin/`,
`/usr/local/bin/`.

## Installation en service (appliance)

```bash
sudo install -Dm755 rd_helper           /opt/remotedisplay/rd_helper
sudo install -Dm755 ../receiver_helper/receiver_code/receiver  /opt/remotedisplay/receiver_app  # ou le binaire CMake
sudo setcap 'cap_sys_nice=eip'          /opt/remotedisplay/receiver_app
sudo install -Dm644 systemd/rd-helper.service /etc/systemd/system/rd-helper.service
# éditer les chemins dans le .service si besoin
sudo systemctl disable --now gdm        # libère la console / le DRM master
sudo systemctl daemon-reload
sudo systemctl enable --now rd-helper
```

Logs : `journalctl -u rd-helper -f` (inclut la sortie `[recv]` du process C++).

## Notes / limites connues

- **Extinction = vrai DPMS off** via `drm_fb_helper` : `bl_power` est ignoré par
  `amdgpu` sur cet iMac et la dalle a un plancher de rétroéclairage, donc
  `brightness 0` n'éteint pas. Seul `echo 4 > /sys/class/graphics/fbN/blank`
  (une fois `amdgpudrmfb` maître, receiver arrêté) coupe réellement panneau +
  rétroéclairage. Conséquence : le réveil refait un modeset (~1-2 s), comme
  n'importe quel moniteur qui sort de veille.
- `/sys/class/drm/*/dpms` est en lecture seule sur ce noyau — pas utilisable.
- `rd_helper` doit tourner en **root** : le receiver enfant a besoin d'être
  DRM master sans session logind, et l'écriture `fbX/blank` / `backlight`
  demande les privilèges.
