#!/usr/bin/env bash
set -euo pipefail

WS_URL=""
SERVER_NAME="TransportBridgeWS"
REPO_URL="https://github.com/chromecide/claude-desktop-transport-bridge.git"
CLONE_DIR="${HOME}/.local/src/claude-desktop-transport-bridge"

usage() {
  cat <<EOF
Usage: $0 --url 'ws://host:port/path' [--name 'ServerName']

Options:
  --url    WebSocket URL for the bridge (required)
  --name   MCP server name in Claude's config (default: TransportBridgeWS)

Example:
  $0 --url 'ws://192.168.30.36:1111/mcp/email%40host.com' --name 'OutlookMCP'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)  WS_URL="${2:-}"; shift 2 ;;
    --name) SERVER_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done
[[ -n "$WS_URL" ]] || { echo "ERROR: --url is required"; usage; exit 1; }

# ------------ Brew / PATH bootstrap ------------
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make brew available in the current shell and future logins
eval "$("$BREW_PREFIX/bin/brew" shellenv)" || true
if ! grep -qF 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
  echo 'eval "$('"$BREW_PREFIX"'/bin/brew shellenv)"' >> "${HOME}/.zprofile"
fi

# ------------ Core deps (idempotent) ------------
echo "Ensuring Node@20, jq, coreutils, git..."
brew update >/dev/null || true
brew install node@20 jq coreutils git || true

# Force Node@20 for THIS run
export PATH="$("$BREW_PREFIX/bin/brew" --prefix node@20)/bin:$PATH"

# Friendly symlinks so GUI apps (Claude) can find them
mkdir -p /usr/local/bin || true
for b in node npm npx; do
  SRC="$("$BREW_PREFIX/bin/brew" --prefix node@20)/bin/$b"
  [[ -x "$SRC" ]] && ln -sf "$SRC" "/usr/local/bin/$b" 2>/dev/null || true
done

# Verify Node version >=20
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: node not found on PATH after install."; exit 1
fi
NODE_MAJ="$(node -v | sed 's/^v//' | cut -d. -f1)"
if [[ "$NODE_MAJ" -lt 20 ]]; then
  echo "ERROR: Node $(node -v) found, but >= v20 required."; exit 1
fi

# ------------ Clone / Install deps / Build ------------
echo "Preparing local source at: ${CLONE_DIR}"
mkdir -p "$(dirname "$CLONE_DIR")"
if [[ -d "$CLONE_DIR/.git" ]]; then
  git -C "$CLONE_DIR" fetch --all --tags --prune || true
  git -C "$CLONE_DIR" reset --hard origin/main || git -C "$CLONE_DIR" reset --hard HEAD
else
  rm -rf "$CLONE_DIR" || true
  git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
fi

cd "$CLONE_DIR"

# Install with dev deps
if [[ -f package-lock.json ]]; then
  npm ci --include=dev
else
  npm install --include=dev
fi

# --- NEW: ensure WebSocket implementation is available at runtime ---
# Add 'ws' as a dependency (idempotent)
if ! npm ls ws >/dev/null 2>&1; then
  npm install ws --save
fi

# Build the project
npm run build

# --- NEW: inject WebSocket polyfill into the built entrypoint (ESM) ---
INDEX_JS="$CLONE_DIR/dist/src/index.js"
if [[ ! -f "$INDEX_JS" ]]; then
  echo "ERROR: built index.js not found at $INDEX_JS"; exit 1
fi

# Only inject once
if ! grep -q 'globalThis\.WebSocket' "$INDEX_JS"; then
  # Insert just after the fetch globals
  perl -0777 -i -pe '
    s/(global\.Response\s*=\s*fetch\.Response\s*;\s*)/$1\nimport WebSocket from "ws";\nglobalThis.WebSocket = WebSocket;\n/s
  ' "$INDEX_JS"
  echo "✔ Injected WebSocket polyfill into dist/src/index.js"
else
  echo "ℹ WebSocket polyfill already present in dist/src/index.js"
fi

# ------------ Global install (link or pack) ------------
set +e
npm link
LINK_RC=$?
set -e

if [[ $LINK_RC -ne 0 ]]; then
  echo "npm link failed; falling back to npm pack + npm install -g"
  PKG_TGZ="$(npm pack)"
  npm install -g "./${PKG_TGZ}"
fi

# Ensure 'claude-bridge' is discoverable
if ! command -v claude-bridge >/dev/null 2>&1; then
  NPM_BIN_DIR="$(npm bin -g)"
  if [[ -x "${NPM_BIN_DIR}/claude-bridge" ]]; then
    ln -sf "${NPM_BIN_DIR}/claude-bridge" /usr/local/bin/claude-bridge 2>/dev/null || true
  fi
fi

if ! command -v claude-bridge >/dev/null 2>&1; then
  echo "ERROR: claude-bridge not found after install. Check 'npm bin -g' and PATH."; exit 1
fi
echo "✔ claude-bridge at: $(command -v claude-bridge)"

# --- NEW (safety): also patch the runtime entrypoint the binary points to, if different ---
BRIDGE_BIN="$(command -v claude-bridge)"
RUNTIME_INDEX="$BRIDGE_BIN"
# Resolve symlink chain to the actual JS file
if [[ -L "$RUNTIME_INDEX" ]]; then
  RESOLVED="$(readlink "$RUNTIME_INDEX")"
  [[ "$RESOLVED" != /* ]] && RUNTIME_INDEX="$(dirname "$BRIDGE_BIN")/$RESOLVED" || RUNTIME_INDEX="$RESOLVED"
fi
if [[ -f "$RUNTIME_INDEX" ]]; then
  if ! grep -q 'globalThis\.WebSocket' "$RUNTIME_INDEX"; then
    perl -0777 -i -pe '
      s/(global\.Response\s*=\s*fetch\.Response\s*;\s*)/$1\nimport WebSocket from "ws";\nglobalThis.WebSocket = WebSocket;\n/s
    ' "$RUNTIME_INDEX" || true
    echo "✔ Ensured WebSocket polyfill in runtime entrypoint"
  fi
fi

# ------------ Configure Claude Desktop MCP ------------
CLAUDE_DIR="${HOME}/Library/Application Support/Claude"
CONFIG_PATH="${CLAUDE_DIR}/claude_desktop_config.json"
mkdir -p "${CLAUDE_DIR}"
[[ -f "${CONFIG_PATH}" ]] || echo '{ "mcpServers": {} }' > "${CONFIG_PATH}"

cp "${CONFIG_PATH}" "${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"

PAYLOAD_JSON="{\"url\":\"${WS_URL}\"}"
TMP="$(mktemp)"
jq --arg name "${SERVER_NAME}" --arg payload "${PAYLOAD_JSON}" '
  .mcpServers = (.mcpServers // {}) |
  .mcpServers[$name] = { "command": "claude-bridge", "args": ["WEBSOCKET", $payload] }
' "${CONFIG_PATH}" > "${TMP}"
mv "${TMP}" "${CONFIG_PATH}"

echo "✔ Updated MCP config: ${CONFIG_PATH}"
jq -r --arg name "${SERVER_NAME}" '.mcpServers[$name]' "${CONFIG_PATH}" || true

# ------------ Quick sanity probe (non-blocking) ------------
if command -v gtimeout >/dev/null 2>&1; then
  gtimeout 3 claude-bridge WEBSOCKET "${PAYLOAD_JSON}" >/dev/null 2>&1 || true
else
  claude-bridge WEBSOCKET "${PAYLOAD_JSON}" >/dev/null 2>&1 & sleep 2; kill $! 2>/dev/null || true
fi

cat <<EONOTE

Done ✅

Next:
  1) Quit & relaunch Claude Desktop to reload the config.
  2) In the MCP pane, confirm '${SERVER_NAME}' is listed.
  3) If your server requires TLS, switch the URL to wss://...

Notes:
  - This script installs 'ws' and injects:
      import WebSocket from "ws";
      globalThis.WebSocket = WebSocket;
    into the bridge's entrypoint so the MCP SDK finds a global WebSocket in Node.
  - If you later pull upstream changes, re-run this script to re-inject after build.

EONOTE
