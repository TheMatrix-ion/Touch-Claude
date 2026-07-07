#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_ID="com.zhihu.claude-touchbar"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
APP_HOME="$HOME/.claude-touchbar"
INSTALL_BIN="$APP_HOME/bin/ClaudeTouchBar"

"$SCRIPT_DIR/build.sh"
mkdir -p "$APP_HOME/bin"
cp "$ROOT_DIR/bin/ClaudeTouchBar" "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
mkdir -p "$HOME/Library/LaunchAgents"

# Install the `clawd` command so the user can show/hide the mascot on demand
# (`clawd wake` / `clawd sleep` / `clawd auto`). Prefer a PATH dir that already
# exists; fall back to ~/bin.
CLAWD_LINK=""
for dir in "$HOME/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
  if [[ -d "$dir" && -w "$dir" ]]; then
    CLAWD_LINK="$dir/clawd"
    break
  fi
done
if [[ -z "$CLAWD_LINK" ]]; then
  mkdir -p "$HOME/bin"
  CLAWD_LINK="$HOME/bin/clawd"
fi
ln -sf "$INSTALL_BIN" "$CLAWD_LINK"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$APP_HOME/launch-agent.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_HOME/launch-agent.err.log</string>
</dict>
</plist>
EOF

UID_VALUE="$(id -u)"
DOMAIN="gui/$UID_VALUE"
SERVICE="$DOMAIN/$AGENT_ID"

launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
if ! launchctl bootstrap "$DOMAIN" "$PLIST_PATH" >/dev/null 2>&1; then
  launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl load "$PLIST_PATH" >/dev/null 2>&1 || true
fi
launchctl enable "$SERVICE" >/dev/null 2>&1 || true
launchctl kickstart -k "$SERVICE" >/dev/null 2>&1 || launchctl kickstart "$SERVICE" >/dev/null 2>&1 || true

echo "Installed LaunchAgent at $PLIST_PATH"
echo "Installed binary at $INSTALL_BIN"
echo "Installed clawd command at $CLAWD_LINK"
echo "Open Claude in a terminal — the Touch Bar should show the Claude mark."
echo "Show/hide on demand:  clawd wake  |  clawd sleep  |  clawd auto"
