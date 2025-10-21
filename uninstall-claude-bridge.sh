#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Starting Claude Bridge uninstaller..."

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

CLONE_DIR="${HOME}/.local/src/claude-desktop-transport-bridge"
CLAUDE_DIR="${HOME}/Library/Application Support/Claude"
CONFIG_PATH="${CLAUDE_DIR}/claude_desktop_config.json"

# --- Stop running bridge processes ---
echo "⛔ Stopping any running claude-bridge processes..."
pkill -f "claude-bridge" 2>/dev/null || true

# --- Remove cloned source ---
if [[ -d "$CLONE_DIR" ]]; then
  echo "🗑 Removing local source clone: $CLONE_DIR"
  rm -rf "$CLONE_DIR"
fi

# --- Remove global NPM install/link ---
echo "🧽 Uninstalling global claude-desktop-transport-bridge package..."
npm uninstall -g claude-desktop-transport-bridge >/dev/null 2>&1 || true
npm unlink -g claude-desktop-transport-bridge >/dev/null 2>&1 || true

# --- Remove global binary symlinks ---
for p in \
  "$BREW_PREFIX/bin/claude-bridge" \
  /usr/local/bin/claude-bridge \
  /usr/bin/claude-bridge; do
  if [[ -L "$p" || -f "$p" ]]; then
    echo "🗑 Removing binary link: $p"
    rm -f "$p"
  fi
done

# --- Remove Node and supporting packages ---
echo "🧩 Uninstalling Node@20 and tools..."
brew uninstall node@20 jq coreutils git >/dev/null 2>&1 || true

# --- Remove symlinks for node/npm/npx ---
for b in node npm npx; do
  rm -f "$BREW_PREFIX/bin/$b" /usr/local/bin/$b 2>/dev/null || true
done

# --- Clear npm cache and local node modules ---
echo "🧽 Cleaning npm and Node cache..."
npm cache clean --force >/dev/null 2>&1 || true
rm -rf "$HOME/.npm" "$HOME/.nvm" "$HOME/.node-gyp" "$HOME/.local/lib/node_modules" "$HOME/.cache" 2>/dev/null || true

# --- Reset launchctl PATH and proxy vars (GUI environment) ---
echo "🧩 Resetting launchctl environment..."
launchctl unsetenv PATH 2>/dev/null || true
launchctl unsetenv NO_PROXY 2>/dev/null || true
launchctl unsetenv no_proxy 2>/dev/null || true
launchctl unsetenv HTTP_PROXY 2>/dev/null || true
launchctl unsetenv HTTPS_PROXY 2>/dev/null || true

# --- Remove Claude MCP config (optional but clean) ---
if [[ -f "$CONFIG_PATH" ]]; then
  echo "🗑 Removing Claude MCP config: $CONFIG_PATH"
  rm -f "$CONFIG_PATH"
fi

# --- Remove installed bridge from Homebrew lib (safety cleanup) ---
find "$BREW_PREFIX/lib/node_modules" -type d -name "claude-desktop-transport-bridge" -exec rm -rf {} + 2>/dev/null || true

# --- Remove leftover logs ---
LOG_PATHS=(
  "$BREW_PREFIX/lib/node_modules/claude-desktop-transport-bridge/dist/src/logs"
  "$HOME/.local/src/claude-desktop-transport-bridge/dist/src/logs"
  "$HOME/.npm/_logs"
)
for lp in "${LOG_PATHS[@]}"; do
  [[ -d "$lp" ]] && rm -rf "$lp"
done

echo ""
echo "✅ Claude Bridge and dependencies fully removed!"
echo ""
echo "To confirm:"
echo "  - node -v   # should show 'command not found'"
echo "  - claude-bridge --help  # should show 'not found'"
echo ""
echo "You can now rerun your installer to test a clean setup:"
echo "bash <(curl -fsSL https://raw.githubusercontent.com/DenysSeptaAutomationTrader/claude-bridge-install/main/install-claude-bridge-ws.sh) \\"
echo "  --url 'ws://192.168.30.36:1111/mcp/denys.septa@automationtrader.com' \\"
echo "  --name 'OutlookMCP'"
echo ""
