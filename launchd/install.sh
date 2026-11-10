#!/bin/bash
# Install icvr as a launchd agent for the current user.
# It must be an agent (not a daemon): Photos needs a logged-in user session.
set -euo pipefail

LABEL="ch.visin.icvr"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/icvr"

ICVR="$(command -v icvr || true)"
if [ -z "$ICVR" ]; then
    echo "icvr not found in PATH. Install it first (see README)." >&2
    exit 1
fi
FFMPEG_DIR="$(dirname "$(command -v ffmpeg)")"

mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$ICVR</string><string>run</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>$FFMPEG_DIR:/usr/bin:/bin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>300</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$LOG_DIR/icvr.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/icvr.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Log: $LOG_DIR/icvr.log"
echo "To stop: launchctl bootout gui/$(id -u)/$LABEL"
