#!/bin/zsh
# mem-agent one-command installer. Idempotent — safe to re-run any time.
#   ./install.sh          suggest mode (proposals only; you confirm each action)
#   ./install.sh --auto   auto_reversible mode (acts alone within the safety rules)
set -e
DIR="${0:A:h}"
AUTO=false
[[ "$1" == "--auto" ]] && AUTO=true

step() { print -P "%F{cyan}▸%f $1"; }

step "Checking toolchain"
command -v swift >/dev/null || { echo "Swift toolchain required (xcode-select --install)"; exit 1; }
command -v node >/dev/null || { echo "Node required for the Claude plugin (brew install node)"; exit 1; }

step "Building daemon (release)"
cd "$DIR/daemon"
swift build -c release >/dev/null

step "Installing daemon under launchd (com.memagent.daemon)"
.build/release/memagent install >/dev/null
step "Installing menu-bar app"
.build/release/memagent menubar-install >/dev/null
step "Registering Chrome native-messaging host"
.build/release/memagent chrome-install >/dev/null

step "Installing Claude plugin dependencies"
cd "$DIR/plugin/mcp"
npm install --no-fund --no-audit >/dev/null 2>&1

step "Waiting for daemon socket"
SOCK="$HOME/Library/Application Support/mem-agent/memagent.sock"
for i in {1..20}; do
  printf '{"id":1,"method":"ping"}\n' | nc -U "$SOCK" 2>/dev/null | grep -q '"ok":true' && break
  sleep 1
done

if $AUTO; then
  step "Setting autonomy: auto_reversible"
  printf '{"id":1,"method":"policy_set","params":{"autonomy":"auto_reversible"}}\n' \
    | nc -U "$HOME/Library/Application Support/mem-agent/memagent.sock" >/dev/null || true
fi

step "Verifying"
"$HOME/.local/bin/memagent" status

print -P "
%F{green}✓ mem-agent installed.%f Two optional finishing moves:

  1. Chrome tab suspension (one manual click Chrome requires):
     chrome://extensions → Developer mode → Load unpacked → $DIR/chrome-extension
     Verify with: memagent chrome-status

  2. The /memory command in Claude Code:
     /plugin marketplace add $DIR
     /plugin install mem-agent@mem-agent-local
     (or try once with: claude --plugin-dir $DIR/plugin)

Autonomy is $($AUTO && echo auto_reversible || echo "suggest — rerun with --auto, or use /memory to change it").
Uninstall everything: memagent uninstall && memagent menubar-uninstall
"
