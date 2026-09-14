# receiver_helper — helper headless du récepteur

Supervise [`receiver_app`](../receiver_code) (démarrage, arrêt, redémarrage auto)
et pilote l'écran de la machine réceptrice : c'est le seul helper supporté,
pensé dès le départ pour **KMS/DRM sans serveur X/Wayland** (pas de dépendance
GTK/Flutter — CLI Dart, compile en binaire natif unique).

## Ce qu'il fait

| Fonction | Implémentation |
|---|---|
| Lance / arrête / suspend / reprend le process `receiver_app` | ✅ + redémarrage auto si crash |
| Écoute UDP `:5002` : `SLP_DETECTED`, `CONN_OK`, `BRIGHTNESS:<n>` | ✅ |
| Extinction écran | arrêt du receiver + `echo 4 > fbN/blank` (DPMS off réel) |
| Rallumage écran | `echo 0 > fbN/blank` + relance du receiver + luminosité réappliquée |
| Luminosité | `brightnessctl`, repli `/sys/class/backlight` |
| Overlay visuel (statut / barre luminosité) | ❌ *(pas fait — nécessiterait un rendu dans le receiver SDL)* |

## Build

Ce dossier (helper) : SDK Dart requis pour compiler, mais **pas** sur la
machine cible — on compile sur un poste de dev et on ne déploie que le
binaire produit (voir « Installation » plus bas).

```bash
./build.sh          # -> ./rd_helper (binaire natif autonome)
```

[`../receiver_code`](../receiver_code) (le programme d'affichage lui-même) se
build séparément, en C++ — voir son propre README.

## Utilisation

```bash
sudo SDL_VIDEODRIVER=kmsdrm ./rd_helper --receiver /chemin/vers/receiver_app
```

Options : `--receiver <path>`, `--port <n>` (déf. 5002), `--no-debug`,
`-- <args>` transmis tels quels au receiver (ex. `-- --width 3840 --height 2160`).

Résolution auto du binaire receiver si `--receiver` absent : `$RD_RECEIVER_BIN`,
puis à côté de `rd_helper`, puis `/opt/remotedisplay/`, `/usr/local/bin/`.

## Installation en service (appliance)

```bash
sudo install -Dm755 rd_helper                     /opt/remotedisplay/rd_helper
sudo install -Dm755 ../receiver_code/build/receiver_app /opt/remotedisplay/receiver_app
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
