---
description: Install or repair the full mem-agent stack (daemon, menu bar, Chrome bridge) automatically
---

Set up mem-agent end to end on this Mac. Work autonomously; only stop for the decisions listed in step 5.

1. Check what exists: run `memagent status` (also try `~/.local/bin/memagent status`). If the daemon responds on the socket, this is a repair/verify run, not a fresh install.

2. Locate the source. If `~/mem-agent/install.sh` exists, use it. Otherwise clone it first:
   `git clone https://github.com/Harsh-Dhingra/mem-agent ~/mem-agent`

3. Run the installer: `zsh ~/mem-agent/install.sh` (build + daemon + menu bar + Chrome host + plugin deps; idempotent). If the build fails, diagnose and fix — the toolchain requirement is Xcode Command Line Tools and Node.

4. Verify each surface and report a checklist to the user:
   - `memagent status` → launchd running + socket responding
   - `memagent predict` → prediction output present
   - `pgrep -x memagent-menubar` → menu-bar app running
   - `memagent chrome-status` → note whether the extension is connected

5. Ask the user two things (use their answers, don't assume):
   - Autonomy: `suggest` (it proposes, they confirm) or `auto_reversible` (it acts alone — reversible actions only, allowlisted targets, ≤4/hour, auto-reverting). Apply via the `policy_set` MCP tool or the socket.
   - Whether they want any apps on the manageable allowlist now (e.g. Spotify, idle Electron helpers). Add via `policy_set`.

6. If chrome-status showed not connected, tell them the one step no script can do — Chrome requires a manual click for unpacked extensions:
   chrome://extensions → enable Developer mode → Load unpacked → `~/mem-agent/chrome-extension`
   Mention it takes ~30 seconds to show connected afterwards, and that tabs are *discarded* (suspended in place, reload on click), never closed.

7. Finish with a one-paragraph summary of what is now running, the current autonomy mode, and that `/memory` gives them the live report.

$ARGUMENTS
