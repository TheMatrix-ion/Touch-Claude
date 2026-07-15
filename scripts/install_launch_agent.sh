#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_ID="com.zhihu.claude-touchbar"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
APP_HOME="$HOME/.claude-touchbar"
INSTALL_BIN="$APP_HOME/bin/ClaudeTouchBar"
INSTALL_TMP="$APP_HOME/bin/.ClaudeTouchBar.install.$$"
INSTALL_ASSETS="$APP_HOME/assets"

"$SCRIPT_DIR/build.sh"
mkdir -p "$APP_HOME/bin" "$INSTALL_ASSETS"
chmod 700 "$APP_HOME" "$APP_HOME/bin" "$INSTALL_ASSETS"
trap 'rm -f "$INSTALL_TMP"' EXIT
cp "$ROOT_DIR/bin/ClaudeTouchBar" "$INSTALL_TMP"
chmod 755 "$INSTALL_TMP"
mv -f "$INSTALL_TMP" "$INSTALL_BIN"
trap - EXIT
cp "$ROOT_DIR/assets/claude-pixel-transparent.png" "$INSTALL_ASSETS/claude-pixel-transparent.png"
cp "$ROOT_DIR/assets/claude-distressed.png" "$INSTALL_ASSETS/claude-distressed.png"
cp "$ROOT_DIR/assets/claude-sleeping.png" "$INSTALL_ASSETS/claude-sleeping.png"
chmod 600 \
  "$INSTALL_ASSETS/claude-pixel-transparent.png" \
  "$INSTALL_ASSETS/claude-distressed.png" \
  "$INSTALL_ASSETS/claude-sleeping.png"
mkdir -p "$HOME/Library/LaunchAgents"

# Install the `clawd` command. Prefer a PATH directory that already exists;
# fall back to ~/bin. Never overwrite an unrelated command.
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
if [[ -e "$CLAWD_LINK" || -L "$CLAWD_LINK" ]]; then
  if [[ ! -L "$CLAWD_LINK" || "$(readlink "$CLAWD_LINK")" != "$INSTALL_BIN" ]]; then
    echo "Refusing to replace unrelated command at $CLAWD_LINK" >&2
    exit 1
  fi
fi
ln -sfn "$INSTALL_BIN" "$CLAWD_LINK"

# Install or migrate the Claude Code Stop hook after the binary is in place.
python3 "$SCRIPT_DIR/configure_stop_hook.py"

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

if ! launchctl print "$SERVICE" >/dev/null 2>&1; then
  echo "Failed to register $SERVICE with launchd" >&2
  echo "The binary and hook are installed, but the background helper is not running." >&2
  exit 1
fi

echo "Installed LaunchAgent at $PLIST_PATH"
echo "Installed binary at $INSTALL_BIN"
echo "Installed mascot assets at $INSTALL_ASSETS"
echo "Installed clawd command at $CLAWD_LINK"
echo "Open a new Claude Code session, then run: clawd status"
echo "Pet actions: clawd feed | clawd sleep | clawd wake | clawd hatch"
echo "Display control: clawd view show | clawd view hide | clawd view auto"
