#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_ID="com.zhihu.claude-touchbar"
PLIST_PATH="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
APP_HOME="$HOME/.claude-touchbar"
INSTALL_APP="$HOME/Applications/Touch Claude.app"
INSTALL_BIN="$APP_HOME/bin/ClaudeTouchBar"

# Remove the hook while its target binary still exists. The helper removes both
# the legacy poke-only registration and the current `_record-stop` command.
python3 "$SCRIPT_DIR/configure_stop_hook.py" --remove

launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true

for link in "$HOME/bin/clawd" "/opt/homebrew/bin/clawd" "/usr/local/bin/clawd"; do
  if [[ -L "$link" && "$(readlink "$link")" == "$INSTALL_BIN" ]]; then
    if ! rm -f "$link"; then
      echo "Warning: could not remove $link" >&2
    fi
  fi
done

rm -f "$PLIST_PATH"
rm -f "$INSTALL_BIN"
rm -rf "$INSTALL_APP"
rm -f \
  "$APP_HOME/assets/claude-pixel-transparent.png" \
  "$APP_HOME/assets/claude-distressed.png" \
  "$APP_HOME/assets/claude-sleeping.png"
rmdir "$APP_HOME/bin" >/dev/null 2>&1 || true
rmdir "$APP_HOME/assets" >/dev/null 2>&1 || true

echo "Removed $PLIST_PATH"
echo "Removed $INSTALL_APP, $INSTALL_BIN, and the clawd symlink"
echo "Preserved local pet state and logs under $APP_HOME"
