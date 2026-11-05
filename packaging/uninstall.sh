#!/bin/bash
# AkiGuard uninstaller. Run as root (the menu bar app asks for your admin password).
# Usage: sudo bash uninstall.sh [USER_HOME]
LABEL="id.wildan.akiguard"
USER_HOME="${1:-}"
CONSOLE_UID="$(stat -f %u /dev/console 2>/dev/null || echo 0)"
launchctl bootout "gui/$CONSOLE_UID" "/Library/LaunchAgents/$LABEL.menu.plist" 2>/dev/null
[ -n "$USER_HOME" ] && launchctl bootout "gui/$CONSOLE_UID" "$USER_HOME/Library/LaunchAgents/$LABEL.menu.plist" 2>/dev/null
pkill -x AkiGuardMenu 2>/dev/null
launchctl bootout system "/Library/LaunchDaemons/$LABEL.plist" 2>/dev/null
/usr/local/bin/akiguard reset >/dev/null 2>&1
rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/LaunchAgents/$LABEL.menu.plist" \
      /usr/local/bin/akiguard /Library/Logs/AkiGuard.log
[ -n "$USER_HOME" ] && rm -f "$USER_HOME/Library/LaunchAgents/$LABEL.menu.plist"
rm -rf "/Library/Application Support/AkiGuard" /Applications/AkiGuard.app
pkgutil --forget id.wildan.akiguard.pkg >/dev/null 2>&1
echo "AkiGuard removed. Charging is back to normal."
exit 0
