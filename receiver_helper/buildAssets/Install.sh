#!/bin/bash

# --- CONFIGURATION ---
APP_NAME="receiver_helper"
INSTALL_DIR="/opt/$APP_NAME"
RECEIVER_BIN="data/bin/receiver_app"

# 1. ROOT PRIVILEGE CHECK
if [ "$EUID" -ne 0 ]; then
  echo "[❌] Please run this script with sudo: sudo ./install.sh"
  exit 1
fi

REAL_USER=${SUDO_USER:-$USER}
echo "Install RemoteDisplay Receiver for user: $REAL_USER..."

# 2. INSTALL SYSTEM TOOLS
echo "Installing system performance tools..."
apt-get update > /dev/null
apt-get install -y cpufrequtils > /dev/null

# 3. KERNEL & CPU OPTIMIZATION (Zero Latency)
echo "Optimizing CPU and Network..."
cat <<EOF > /etc/sysctl.d/99-thunderbolt-streaming.conf
net.core.rmem_max=41943040
net.core.rmem_default=41943040
net.core.netdev_max_backlog=5000
EOF
sysctl -p /etc/sysctl.d/99-thunderbolt-streaming.conf > /dev/null

echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils
systemctl restart cpufrequtils

# 4. COPYING PRE-COMPILED FILES
echo "Installing application files..."
mkdir -p "$INSTALL_DIR"
cp -r ./* "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/$APP_NAME"
chmod +x "$INSTALL_DIR/$RECEIVER_BIN"

# 5. GRANTING REAL-TIME CAPABILITIES
echo "Granting real-time privileges to the C++ engine..."
setcap 'cap_sys_nice=eip' "$INSTALL_DIR/$RECEIVER_BIN"
ln -sf "$INSTALL_DIR/$APP_NAME" "/usr/local/bin/$APP_NAME"

# 6. CONFIGURE AUTOSTART (Via Desktop Entry)
echo "🔄 Configuring automatic startup on boot..."
AUTOSTART_DIR="/home/$REAL_USER/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
chown "$REAL_USER":"$REAL_USER" "$AUTOSTART_DIR"

cat <<EOF > "$AUTOSTART_DIR/$APP_NAME.desktop"
[Desktop Entry]
Type=Application
Exec=$INSTALL_DIR/$APP_NAME
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Thunderbolt Receiver
Comment=Starts the display receiver automatically
EOF
chown "$REAL_USER":"$REAL_USER" "$AUTOSTART_DIR/$APP_NAME.desktop"

# 7. AUTOMATE 'AUTOMATIC LOGIN' (GDM3)
# This forces Ubuntu to bypass the password screen on boot
echo "🔓 Enabling Automatic Login for $REAL_USER..."
GDM_CUSTOM="/etc/gdm3/custom.conf"
if [ -f "$GDM_CUSTOM" ]; then
    # Uncomment and set the automatic login variables
    sed -i "s/^# *AutomaticLoginEnable *=.*/AutomaticLoginEnable = true/" "$GDM_CUSTOM"
    sed -i "s/^# *AutomaticLogin *=.*/AutomaticLogin = $REAL_USER/" "$GDM_CUSTOM"
    # If they didn't exist commented out, append them
    grep -q "^AutomaticLoginEnable" "$GDM_CUSTOM" || sed -i '/\[daemon\]/a AutomaticLoginEnable = true' "$GDM_CUSTOM"
    grep -q "^AutomaticLogin = $REAL_USER" "$GDM_CUSTOM" || sed -i "/\[daemon\]/a AutomaticLogin = $REAL_USER" "$GDM_CUSTOM"
fi

# 8. MAKE THE OS INVISIBLE (Black wallpaper, hide dock, disable sleep)
echo "☀️ Stripping the Ubuntu UI (Black screen, no sleep, hidden dock)..."
# We must use 'su' to run gsettings as the actual user connected to DBUS
su - "$REAL_USER" -c "
    # Disable Screen Blanking and Sleep
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'

    # Set desktop background to solid black
    gsettings set org.gnome.desktop.background picture-options 'none'
    gsettings set org.gnome.desktop.background primary-color '#000000'

    # Hide the Ubuntu Dock
    gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed false
"

echo "=================================================================="
echo "Installation Complete!"
echo ""
echo "   The iMac has been successfully converted into a Display."
echo "   - It will now log in automatically on boot."
echo "   - The desktop background is pitch black."
echo "   - The app will launch immediately."
echo "   - The CPU is locked to maximum performance."
echo ""
echo "   Please REBOOT the iMac now to apply all changes."
echo "=================================================================="
