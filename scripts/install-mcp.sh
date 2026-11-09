#!/bin/zsh
# Builds the Srpski MCP server, installs it next to the app's data and registers it with Claude Desktop.
set -euo pipefail
cd "$(dirname "$0")/../Packages/SrbCore"

swift build -c release --product srpski-mcp
BIN_DIR="$HOME/Library/Application Support/Srpski/bin"
mkdir -p "$BIN_DIR"
# Replace, don't overwrite: copying over a signed binary in place gets it killed (exit 137).
rm -f "$BIN_DIR/srpski-mcp"
cp .build/release/srpski-mcp "$BIN_DIR/srpski-mcp"

CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
python3 - "$CONFIG" "$BIN_DIR/srpski-mcp" <<'EOF'
import json, os, sys
path, binary = sys.argv[1], sys.argv[2]
config = json.load(open(path)) if os.path.exists(path) else {}
config.setdefault("mcpServers", {})["srpski"] = {"command": binary}
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(config, open(path, "w"), indent=2, ensure_ascii=False)
EOF
echo "Installed $BIN_DIR/srpski-mcp and registered it in Claude Desktop. Restart Claude Desktop to load it."
# A running Claude Desktop keeps its config in memory and writes it back on any settings change.
pgrep -x Claude >/dev/null && echo "Claude Desktop is running and may overwrite the config: quit it (⌘Q) and run this again." || true
