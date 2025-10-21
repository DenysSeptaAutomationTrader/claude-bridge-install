#!/usr/bin/env bash
set -euo pipefail

WS_URL=""
SERVER_NAME="TransportBridgeWS"

usage() {
  cat <<EOF
Usage: $0 --url 'ws://host:port/path' [--name 'ServerName']

Installs Claude Desktop Transport Bridge (WebSocket) and configures Claude Desktop.

Options:
  --url   WebSocket URL for the bridge (required)
  --name  MCP server name in Claude's config (default: TransportBridgeWS)

Notes:
  - Bridge requires Node.js >= 20 and npm. (Per upstream README)
EOF
}

# --- Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)  WS_URL="${2:-}"; shift 2 ;;
    --name) SERVER_NAME="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done
[[ -n "$WS_URL" ]] || { echo "ERROR: --url is required"; usage; exit 1; }

# --- Arch & Homebrew prefix
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

# --- Ensure Homebrew
if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
export PATH="${BREW_PREFIX}/bin:${PATH}"

# --- Brew prerequisites
echo "Installing prerequisites (jq, coreutils, Node.js >=20)..."
brew update >/dev/null

# Prefer node@20 explicitly (bridge requires >=20; sticking to 20.x avoids surprises)
if ! brew list node@20 >/dev/null 2>&1; then
  brew install node@20
fi

# jq for safe JSON edits
brew list jq >/dev/null 2>&1 || brew install jq

# coreutils for gtimeout (macOS lacks `timeout`)
brew list coreutils >/dev/null 2>&1 || brew install coreutils

# Make sure Node 20 is on PATH for this shell and typical GUI contexts
NODE_BIN_DIR="$(brew --prefix node@20)/bin"
export PATH="${NODE_BIN_DIR}:${PATH}"

# Try to place helper symlinks so GUI apps (Claude) can find binaries
ensure_link() {
  local src="$1" dst="$2"
  if [[ -x "$src" ]]; then
    # Attempt without sudo first; if not writable, warn instead of failing
    if ln -sf "$src" "$dst" 2>/dev/null; then
      :
    else
      echo "Note: Could not write $dst (permission). Consider: sudo ln -sf \"$src\" \"$dst\""
    fi
  fi
}

mkdir -p /usr/local/bin || true
ensure_link "${NODE_BIN_DIR}/node" /usr/local/bin/node
ensure_link "${NODE_BIN_DIR}/npm"  /usr/local/bin/npm
ensure_link "${NODE_BIN_DIR}/npx"  /usr/local/bin/npx

# --- Verify Node version
if command -v node >/dev/null 2>&1; then
  NODE_MAJ="$(node -v | sed 's/^v//' | cut -d. -f1)"
  if [[ "$NODE_MAJ" -lt 20 ]]; then
    echo "ERROR: Node $(node -v) found, but >= v20 is required. Check PATH or reinstall node@20."
    exit 1
  fi
else
  echo "ERROR: node not found on PATH after installation."
  exit 1
fi

# --- Install the bridge (global)
echo "Installing claude-desktop-transport-bridge globally..."
npm install -g "github:chromecide/claude-desktop-transport-bridge"

# Ensure the CLI is reachable
CLAUDE_BRIDGE_BIN="$(command -v claude-bridge || true)"
if [[ -z "$CLAUDE_BRIDGE_BIN" ]]; then
  NPM_BIN_DIR="$(npm bin -g)"
  ensure_link "${NPM_BIN_DIR}/claude-bridge" /usr/local/bin/claude-bridge
  CLAUDE_BRIDGE_BIN="$(command -v claude-bridge || true)"
fi
if [[ -z "$CLAUDE_BRIDGE_BIN" ]]; then
  echo "ERROR: claude-bridge not found on PATH after install. Check 'npm bin -g' and PATH."
  exit 1
fi
echo "✔ claude-bridge at: $CLAUDE_BRIDGE_BIN"

# --- Configure Claude Desktop MCP
CLAUDE_DIR="${HOME}/Library/Application Support/Claude"
CONFIG_PATH="${CLAUDE_DIR}/claude_desktop_config.json"
mkdir -p "${CLAUDE_DIR}"

# Create minimal config if missing
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo '{ "mcpServers": {} }' > "${CONFIG_PATH}"
fi

# Backup
cp "${CONFIG_PATH}" "${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"

PAYLOAD_JSON="{\"url\":\"${WS_URL}\"}"

TMP_FILE="$(mktemp)"
jq --arg name "${SERVER_NAME}" \
   --arg payload "${PAYLOAD_JSON}" '
  .mcpServers = (.mcpServers // {}) |
  .mcpServers[$name] = {
    "command": "claude-bridge",
    "args": ["WEBSOCKET", $payload]
  }' \
  "${CONFIG_PATH}" > "${TMP_FILE}"
mv "${TMP_FILE}" "${CONFIG_PATH}"

echo "✔ Updated Claude MCP config: ${CONFIG_PATH}"
jq -r --arg name "${SERVER_NAME}" '.mcpServers[$name]' "${CONFIG_PATH}" || true
echo

# --- Quick sanity check (3s)
# Prefer gtimeout if present; otherwise run a short non-blocking probe
echo "Running quick sanity check..."
if command -v gtimeout >/dev/null 2>&1; then
  set +e
  gtimeout 3 claude-bridge WEBSOCKET "${PAYLOAD_JSON}" >/dev/null 2>&1
  set -e
else
  # Fire-and-forget in background; give it a moment, then kill
  claude-bridge WEBSOCKET "${PAYLOAD_JSON}" >/dev/null 2>&1 &
  BRIDGE_PID=$!
  sleep 2
  kill "$BRIDGE_PID" >/dev/null 2>&1 || true
fi
echo "✔ Sanity check invoked."

cat <<'EONOTE'

Done ✅

Next steps:
1) Quit and relaunch Claude Desktop so it reloads the config.
2) Open the hammer/wrench panel and confirm the server name is listed.
3) If the GUI can't find node/npm/claude-bridge, ensure /usr/local/bin and /opt/homebrew/bin are visible to GUI apps
   or add explicit symlinks as noted above.

Security tip: Your URL uses ws:// (plaintext). Prefer wss:// with auth where possible.
EONOTE
