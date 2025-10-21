#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

echo "🧹 Cleaning up Claude Bridge installation and dependencies..."

# --- Stop any running claude-bridge processes ---
pkill -f "claude-bridge" 2>/dev/null || true

# --- Remove local clone ---
CLONE_DIR="${HOME}/.local/src/claude-desktop-transport-bridge"
if [[ -d "$CLONE_DIR" ]]; then
  echo "🗑 Removing local clone: $CLONE_DIR"
  rm -rf "$CLONE_DIR"
fi

# --- Remove global npm install/link ---
echo "🗑 Uninstalling global claude-desktop-transport-bridge..."
npm uninstall -g claude-desktop-transport-bridge >/dev/null 2>&1 || true
npm unlink -g claude-desktop-transport-bridge >/dev/null 2>&1 || true

# --- Remove global claude-bridge binary and symlinks ---
for p in /usr/local/bin/claude-bridge "$BREW_PREFIX/bin/claude-bridge"; do
  if [[ -L "$p" || -f "$p" ]]; then
    echo "🗑 Removing binary link: $p"
    rm -f "$p"
  fi
done

# --- Remove Node@20 and related packages ---
echo "🗑 Uninstalling Node@20 and Homebrew packages..."
brew uninstall node@20 jq coreutils git >/dev/null 2>&1 || true

# --- Remove npm global cache and node_modules ---
echo "🧽 Cleaning NPM global modules and cache..."
npm cache clean --force >/dev/null 2>&1 || true
rm -rf "$HOME/.npm" "$HOME/.nvm" "$HOME/.node-gyp" "$HOME/.local/lib/node_modules" 2>/dev/null || true

# --- Remove Homebrew symlinks for node/npm/npx ---
for b in node npm npx; do
  rm -f "$BREW_PREFIX/bin/$b" /usr/local/bin/$b 2>/dev/null || true
done

# --- Reset PATH from launchctl (GUI apps) ---
echo "🧩 Resetting launchctl PATH..."
launchctl unsetenv PATH 2>/dev/null || true
launchctl unsetenv NO_PROXY 2>/dev/null || true
launchctl unsetenv no_proxy 2>/dev/null || true
launchctl unsetenv HTTP_PROXY 2>/dev/null || true
launchctl unsetenv HTTPS_PROXY 2>/dev/null || true

# --- Optional: remove Claude MCP config if you want a clean start ---
CLAUDE_DIR="${HOME}/Library/Application Support/Claude"
CONFIG_PATH="${CLAUDE_DIR}/claude_desktop_config.json"
if [[ -f "$CONFIG_PATH" ]]; then
  echo "🗑 Removing MCP config: $CONFIG_PATH"
  rm -f "$CONFIG_PATH"
fi

# --- Cleanup logs ---
find "$BREW_PREFIX/lib/node_modules" -type d -name "claude-desktop-transport-bridge" -exec rm -rf {} + 2>/dev/null || true
rm -rf "$BREW_PREFIX/lib/node_modules/claude-desktop-transport-bridge" 2>/dev/null || true
rm -rf "$HOME/.npm/_logs" "$HOME/.cache" 2>/dev/null || true

echo ""
echo "✅ Cleanup complete. System restored to pre-install state."
echo ""
echo "Next:"
echo "  • Reopen Terminal or run: exec \$SHELL -l"
echo "  • You can now re-run your install script to test a fresh setup."
