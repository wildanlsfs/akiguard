#!/bin/bash
# AkiGuard uninstaller: menghentikan daemon, mengembalikan charging normal, menghapus file.
set -uo pipefail
LABEL="id.wildan.akiguard"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.menu.plist"

launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null
pkill -x AkiGuardMenu 2>/dev/null
rm -f "$AGENT_PLIST"

sudo /bin/bash <<'ROOT'
LABEL="id.wildan.akiguard"
launchctl bootout system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null
/usr/local/bin/akiguard reset 2>/dev/null
rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/bin/akiguard /Library/Logs/AkiGuard.log
rm -rf "/Library/Application Support/AkiGuard" /Applications/AkiGuard.app
ROOT
echo "AkiGuard dihapus. Charging kembali normal (BCLM 100%)."
