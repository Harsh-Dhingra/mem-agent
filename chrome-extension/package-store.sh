#!/bin/zsh
# Package the extension for Chrome Web Store submission.
# The uploaded zip must NOT contain the "key" field — the store assigns its
# own id (after publish, run: memagent chrome-install --store-id <that id>).
set -e
DIR="${0:A:h}"
OUT="$DIR/../dist"
mkdir -p "$OUT"
STAGE="$(mktemp -d)"
cp "$DIR/sw.js" "$STAGE/"
python3 - "$DIR/manifest.json" "$STAGE/manifest.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
m.pop("key", None)  # store assigns the id
json.dump(m, open(sys.argv[2], "w"), indent=2)
EOF
VERSION=$(python3 -c "import json;print(json.load(open('$STAGE/manifest.json'))['version'])")
ZIP="$OUT/mem-agent-extension-$VERSION.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -q "$ZIP" manifest.json sw.js)
rm -rf "$STAGE"
echo "store package: $ZIP"
echo ""
echo "Submit at https://chrome.google.com/webstore/devconsole (one-time \$5 fee):"
echo "  1. New item → upload the zip"
echo "  2. Category: Productivity/Tools · Privacy: no remote code, no data collected"
echo "     (all tab data goes only to the local mem-agent daemon over native messaging)"
echo "  3. After publish, note the extension id and run:"
echo "       memagent chrome-install --store-id <id>"
