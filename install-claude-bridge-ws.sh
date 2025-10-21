#!/usr/bin/env bash
set -euo pipefail


WS_URL=""
SERVER_NAME="TransportBridgeWS"

print_usage() {
  cat <<EOF
Usage: $0 --url 'ws://host:port/path' [--name 'ServerName']

Installs Claude Desktop Transport Bridge (WebSocket) and configures Claude Desktop.

Options:
  --url   WebSocket URL for the bridge (required)
  --name  MCP server name in Claude's config (default: TransportBridgeWS)
EOF
}

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)  WS_URL="${2:-}"; shift 2 ;;
    --name) SERVER_NAME="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "Unknown option: $1"; print_usage; exit 1 ;;
  esac
done

if [[ -z "${WS_URL}" ]]; then
  echo "ERROR: --url is required."
  print_usage
  exit 1
fi

# Detect architecture and Homebrew prefix
ARCH="$(uname -m)"
if [[ "${ARCH}" == "arm64" ]]; then
  BREW_PREFIX="/opt/homebrew"
else
  BREW_PREFIX="/usr/local"
fi

# Ensure Homebrew
if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
export PATH="${BREW_PREFIX}/bin:${PATH}"

# Install prerequisites
echo "Installing prerequisites (jq, Node.js >=20)..."
brew update >/dev/null
if ! brew list node@20 >/dev/null 2>&1; then
  brew install node@20
fi
brew install jq || true

NODE_BIN_DIR="$(brew --prefix node@20)/bin"
export PATH="${NODE_BIN_DIR}:${PATH}"

# Make sure node/npm are in a GUI-accessible path
mkdir -p /usr/local/bin || true
ln -sf "${NODE_BIN_DIR}/node" /usr/local/bin/node
ln -sf "${NODE_BIN_DIR}/npm"  /usr/local/bin/npm
ln -sf "${NODE_BIN_DIR}/npx"  /usr/local/bin/npx

# Install claude-desktop-transport-bridge globally
echo "Installing claude-desktop-transport-bridge..."
npm install -g "github:chromecide/claude-desktop-transport-bridge"

# Ensure claude-bridge is visible in PATH
if ! command -v claude-bridge >/dev/null 2>&1; then
  BIN_DIR="$(npm bin -g)"
  ln -sf "${BIN_DIR}/claude-bridge" /usr/local/bin/claude-bridge
fi

if ! command -v claude-bridge >/dev/null 2>&1; then
  echo "ERROR: claude-bridge binary not found. Check your npm global path."
  exit 1
fi

echo "✔ claude-bridge installed at $(command -v claude-bridge)"

# Configure Claude Desktop MCP
CLAUDE_DIR="${HOME}/Library/Application Support/Claude"
CONFIG_PATH="${CLAUDE_DIR}/claude_desktop_config.json"
mkdir -p "${CLAUDE_DIR}"

# Create minimal config if missing
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo '{ "mcpServers": {} }' > "${CONFIG_PATH}"
fi

cp "${CONFIG_PATH}" "${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"

PAYLOAD_JSON="{\"url\":\"${WS_URL}\"}"

TMP_FILE="$(mktemp)"
jq --arg name "${SERVER_NAME}" \
   --arg payload "${PAYLOAD_JSON}" \
   '.mcpServers = (.mcpServers // {}) |
    .mcpServers[$name] = {
      "command": "claude-bridge",
      "args": ["WEBSOCKET", $payload]
    }' \
   "${CONFIG_PATH}" > "${TMP_FILE}"

mv "${TMP_FILE}" "${CONFIG_PATH}"

echo "✔ Updated Claude Desktop config: ${CONFIG_PATH}"
echo
jq -r --arg name "${SERVER_NAME}" '.mcpServers[$name]' "${CONFIG_PATH}" || true
echo

# Sanity check
echo "Running quick sanity check..."
set +e
timeout 3 claude-bridge WEBSOCKET "${PAYLOAD_JSON}" >/dev/null 2>&1
set -e
echo "✔ Sanity check done."

cat <<EONOTE

Installation complete ✅

Next steps:
1. Restart Claude Desktop.
2. Verify '${SERVER_NAME}' is listed in Claude’s MCP servers.
3. If not detected, ensure /usr/local/bin and ${BREW_PREFIX}/bin are in the GUI PATH.

EONOTE
