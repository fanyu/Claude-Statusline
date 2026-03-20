#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/statusline.sh"
DEST="$HOME/.claude/statusline.sh"

# Validate dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install: brew install jq"; exit 1; }

# Backup existing if it exists and differs
if [ -f "$DEST" ] && ! diff -q "$SRC" "$DEST" >/dev/null 2>&1; then
    backup="${DEST}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DEST" "$backup"
    echo "Backed up existing statusline to: $backup"
fi

cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "Installed: $DEST"

# Update settings.json if statusLine key is absent
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    current=$(jq -r '.statusLine.type // empty' "$SETTINGS" 2>/dev/null)
    if [ -z "$current" ]; then
        tmp=$(mktemp)
        jq '.statusLine = {"type": "command", "command": "bash \"$HOME/.claude/statusline.sh\""}' \
            "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
        echo "Updated: $SETTINGS"
    else
        echo "Note: settings.json statusLine already configured — not modified"
    fi
fi

echo ""
echo "Done. Restart Claude Code to activate the statusline."
