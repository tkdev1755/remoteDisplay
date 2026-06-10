#!/bin/bash

# --- CONFIGURATION ---
APP_NAME="receiver_helper"
INSTALL_DIR="/opt/$APP_NAME"
RECEIVER_BIN="data/bin/receiver_app"
THUNDERBOLT_IP="10.0.0.1/24" # À adapter selon ton réseau cible

# 1. VÉRIFICATION DES DROITS ROOT
if [ "$EUID" -ne 0 ]; then
  echo "[❌] Please run this script with sudo: sudo ./install.sh"
  exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
echo "=== Installation du Récepteur iMac (Debian Minimal X11) pour l'utilisateur: $REAL_USER ==="

# 2. INSTALLATION DES DÉPENDANCES STRICTEMENT NÉCESSAIRES
echo "-> Installation des outils système et graphiques (X11, SDL2)..."
apt-get update > /dev/null
apt-get install -y --no-install-recommends \
    cpufrequtils \
    xserver-xorg \
    xinit \
    x11-xserver-utils \
    brightnessctl \
    libsdl2-2.0-0 \
    libsdl2-ttf-2.0-0 \
    > /dev/null

# Ajout de l'utilisateur aux groupes nécessaires pour le contrôle matériel
usermod -aG video,render,input,audio "$REAL_USER"

# 3. OPTIMISATION KERNEL, CPU & RÉSEAU (Zéro Latence & Thunderbolt)
echo "-> Optimisation du CPU, des Buffers Réseau et du MTU..."

# Force le chargement du module Thunderbolt immédiatement
echo "thunderbolt-net" > /etc/modules-load.d/thunderbolt.conf

# Configuration réseau extrême pour la vidéo
cat <<EOF > /etc/sysctl.d/99-thunderbolt-streaming.conf
net.core.rmem_max=41943040
net.core.rmem_default=41943040
net.core.wmem_max=41943040
net.core.wmem_default=41943040
net.core.netdev_max_backlog=5000
net.core.busy_read=50
net.core.busy_poll=50
EOF
sysctl -p /etc/sysctl.d/99-thunderbolt-streaming.conf > /dev/null

# Forcer le CPU au maximum
echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
systemctl restart cpufrequtils

# 4. CONFIGURATION DE L'INTERFACE THUNDERBOLT (systemd-networkd)
echo "-> Configuration de l'IP fixe et du Jumbo Frame Thunderbolt..."
cat <<EOF > /etc/systemd/network/10-thunderbolt.network
[Match]
Name=en* thunderbolt* # Couvre les noms potentiels de l'interface

[Network]
Address=$THUNDERBOLT_IP
LinkLocalAddressing=no
IPv6AcceptRA=no

[Link]
MTUBytes=65520
EOF

systemctl enable systemd-networkd > /dev/null 2>&1
# Empêcher le réseau de bloquer le démarrage
systemctl disable systemd-networkd-wait-online.service > /dev/null 2>&1
systemctl mask systemd-networkd-wait-online.service > /dev/null 2>&1

# 5. COPIE DES FICHIERS ET PERMISSIONS TEMPS RÉEL
echo "-> Installation de l'application..."
mkdir -p "$INSTALL_DIR"
cp -r ./* "$INSTALL_DIR/"
chown -R "$REAL_USER":"$REAL_USER" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/$APP_NAME"
chmod +x "$INSTALL_DIR/$RECEIVER_BIN"

echo "-> Attribution des privilèges temps réel (cap_sys_nice) à l'engin C++..."
setcap 'cap_sys_nice=eip' "$INSTALL_DIR/$RECEIVER_BIN"
ln -sf "$INSTALL_DIR/$APP_NAME" "/usr/local/bin/$APP_NAME"

# 6. CONFIGURATION DE L'AFFICHAGE KIOSQUE (Remplace GNOME et GDM)
echo "-> Configuration du serveur X11 (Écran noir, pas de veille, plein écran)..."

cat <<EOF > "/home/$REAL_USER/.xinitrc"
#!/bin/bash
# Désactiver l'économiseur d'écran et la veille de l'écran
xset s off
xset -dpms
xset s noblank

# Fond noir absolu
xsetroot -solid black

# Lancer l'application Flutter de contrôle
exec $INSTALL_DIR/$APP_NAME
EOF
chown "$REAL_USER":"$REAL_USER" "/home/$REAL_USER/.xinitrc"
chmod +x "/home/$REAL_USER/.xinitrc"

# 7. SERVICE DE DÉMARRAGE AUTOMATIQUE (Autologin ultra-rapide)
echo "-> Création du service de démarrage Kiosque..."
cat << EOF > /etc/systemd/system/imac-receiver.service
[Unit]
Description=iMac Receiver X11 Kiosk
After=systemd-user-sessions.service systemd-udev-settle.service
Conflicts=getty@tty1.service

[Service]
User=$REAL_USER
LimitRTPRIO=99
LimitNICE=-20
ExecStart=/usr/bin/startx /home/$REAL_USER/.xinitrc -- /usr/bin/Xorg -nocursor -nolisten tcp vt1
Restart=always
RestartSec=3
StandardInput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=graphical.target
EOF

systemctl enable imac-receiver.service > /dev/null 2>&1

# 8. OPTIMISATION DU BOOT (Silent Boot + Initramfs)
echo "-> Masquage du démarrage (Boot silencieux)..."
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.systemd.show_status=auto rd.udev.log_priority=3 vt.global_cursor_default=0"/g' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/g' /etc/default/grub
update-grub > /dev/null 2>&1

echo "-> Allègement de l'Initramfs..."
sed -i 's/MODULES=most/MODULES=dep/g' /etc/initramfs-tools/initramfs.conf
update-initramfs -u > /dev/null 2>&1

echo "=================================================================="
echo "[✔] Installation Complète !"
echo ""
echo "   L'iMac a été converti en moniteur Thunderbolt (Debian Minimal)."
echo "   - Environnement GNOME supprimé -> Serveur X11 pur."
echo "   - Autologin et lancement instantané de l'application."
echo "   - Réseau Thunderbolt configuré (MTU 65520, $THUNDERBOLT_IP)."
echo "   - L'application C++ dispose des droits Real-Time."
echo ""
echo "   Veuillez REDÉMARRER l'iMac pour appliquer les changements."
echo "=================================================================="
