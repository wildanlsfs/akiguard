#!/bin/bash
# AkiGuard installer. Jalankan sebagai user biasa:  ./install.sh
# (akan meminta password admin untuk memasang daemon)
set -euo pipefail
cd "$(dirname "$0")"

LABEL="id.wildan.akiguard"
CONF_DIR="/Library/Application Support/AkiGuard"
DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.menu.plist"
APP="/Applications/AkiGuard.app"
ME="$(id -un)"

if [ "$(id -u)" -eq 0 ]; then
  echo "Jalankan tanpa sudo: ./install.sh (password akan diminta saat perlu)"; exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Command Line Tools belum terpasang. Jalankan: xcode-select --install, lalu ulangi."; exit 1
fi

echo "==> Kompilasi daemon"
mkdir -p build
clang -O2 -Wall -Wno-deprecated-declarations -o build/akiguard \
  src/smc.c src/akiguard.c -framework IOKit -framework CoreFoundation

echo "==> Kompilasi menu bar app"
swiftc -O -o build/AkiGuardMenu src/AkiGuardMenu.swift
rm -rf build/AkiGuard.app
mkdir -p build/AkiGuard.app/Contents/MacOS
cp build/AkiGuardMenu build/AkiGuard.app/Contents/MacOS/AkiGuardMenu
cat > build/AkiGuard.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AkiGuard</string>
  <key>CFBundleIdentifier</key><string>id.wildan.akiguard.menu</string>
  <key>CFBundleExecutable</key><string>AkiGuardMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - build/AkiGuard.app >/dev/null 2>&1 || true

echo "==> Memasang (butuh password admin)"
sudo /bin/bash -s -- "$ME" "$PWD" <<'ROOT'
set -euo pipefail
ME="$1"; SRC="$2"
LABEL="id.wildan.akiguard"
CONF_DIR="/Library/Application Support/AkiGuard"
DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"

launchctl bootout system "$DAEMON_PLIST" 2>/dev/null || true

mkdir -p /usr/local/bin
install -m 755 -o root -g wheel "$SRC/build/akiguard" /usr/local/bin/akiguard

mkdir -p "$CONF_DIR"
[ -f "$CONF_DIR/akiguard.conf" ] || cp "$SRC/config/akiguard.conf.default" "$CONF_DIR/akiguard.conf"
# Folder milik Anda supaya menu bar bisa menyimpan pengaturan tanpa password
chown "$ME":staff "$CONF_DIR" "$CONF_DIR/akiguard.conf"
chmod 755 "$CONF_DIR"; chmod 644 "$CONF_DIR/akiguard.conf"

cat > "$DAEMON_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/local/bin/akiguard</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Library/Logs/AkiGuard.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/AkiGuard.log</string>
</dict></plist>
EOF
chown root:wheel "$DAEMON_PLIST"; chmod 644 "$DAEMON_PLIST"
touch /Library/Logs/AkiGuard.log; chmod 644 /Library/Logs/AkiGuard.log

rm -rf /Applications/AkiGuard.app
cp -R "$SRC/build/AkiGuard.app" /Applications/AkiGuard.app
chown -R "$ME":admin /Applications/AkiGuard.app

launchctl bootstrap system "$DAEMON_PLIST"
ROOT

echo "==> Menu bar otomatis jalan saat login"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL.menu</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AkiGuardMenu</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || open "$APP"

sleep 3
echo
/usr/local/bin/akiguard keys || true
echo
/usr/local/bin/akiguard status || true
echo
echo "Selesai. Ikon AkiGuard ada di menu bar. Log: /Library/Logs/AkiGuard.log"
echo "Saran: matikan 'Optimized Battery Charging' di System Settings > Battery agar tidak bentrok."
