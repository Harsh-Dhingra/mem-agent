# mem-agent

An autonomous memory-management agent for macOS: a tiny always-on daemon that
watches memory pressure, detects per-process leaks, and predicts
time-to-critical — plus a Claude Code plugin that turns Claude into the
reasoning layer over that live data.

**Architecture:** LLM proposes, deterministic engine disposes. The daemon does
all monitoring, history, and prediction with zero LLM involvement; Claude (in a
session via MCP, or headlessly via `claude -p` in Phase D) only ever reasons
over pre-digested state and picks from a policy-filtered action menu.

Every non-trivial mechanism is research-grounded — see [RESEARCH.md](RESEARCH.md)
for the paper-by-paper map (Autopilot, TMO/Senpai, PSI, Page-Hinkley,
PrecogMF, SmartLMK, PREPP, Iqbal-Horvitz, TabRanker, and more).

```
launchd daemon (Swift)                            Claude Code plugin
┌────────────────────────────────────┐            ┌──────────────────────┐
│ sensors → SQLite history           │ unix sock  │ MCP server (Node)    │
│ ├ damped-Holt predictor + MC band  │◄──────────►│ /memory command      │
│ ├ Page-Hinkley regime detector     │  ndjson    │                      │
│ ├ PSI-style thrash gauge (gate)    │            └──────────────────────┘
│ ├ Theil-Sen/Mann-Kendall leaks     │            menu-bar app · Chrome
│ ├ per-app learned baselines        │            tab bridge (discard)
│ ├ usage model (PPM+frecency+dwell) │
│ └ validator → reversible actions   │
└────────────────────────────────────┘
```

## Quick start

One command installs everything (daemon, menu bar, Chrome host, plugin deps) and is safe to re-run:

```bash
git clone https://github.com/Harsh-Dhingra/mem-agent ~/mem-agent
zsh ~/mem-agent/install.sh          # proposals only; add --auto to let it act alone
```

Or, from inside Claude Code with the plugin loaded, just run `/memory-setup` and
the agent installs and verifies the whole stack for you.

Manual equivalents:

```bash
make build          # swift build -c release
make test           # swift run selftest (93 checks incl. live sensors)
make install        # copy binary + load launchd agent com.memagent.daemon
make plugin         # npm install for the MCP server
```

Try the plugin for one session:

```bash
claude --plugin-dir "$(pwd)/plugin"
```

Or install it persistently (this repo root doubles as a local marketplace):

```
/plugin marketplace add /path/to/mem-agent
/plugin install mem-agent@mem-agent-local
```

Then in any Claude Code session: `/memory`.

## CLI

```
memagent snapshot          # one-shot state + top consumers (no daemon needed)
memagent top | predict | anomalies | history <pid>    # served by the daemon
memagent propose [--llm]   # policy-validated recovery plan
memagent execute <id>      # run one allowed action (re-validated first)
memagent escalate --dry-run # full LLM drill, executes nothing
memagent run               # daemon in the foreground
memagent stress --mb 1024  # allocate real pages to test detection (no sudo)
memagent install | uninstall | status | logs
memagent chrome-install | chrome-status
memagent menubar-install | menubar-uninstall
memagent policy            # print ~/.config/mem-agent/policy.json
```

## How it measures

- System: `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level`
  (1/2/4 = normal/warn/critical), plus `DispatchSource.makeMemoryPressureSource`
  for kernel push notifications on transitions.
- Per-process: `proc_pid_rusage` → `ri_phys_footprint` (the same number
  Activity Monitor shows). Processes the kernel refuses (other users) fall back
  to RSS from one `ps` sweep. No root, no entitlements.
- History: SQLite (WAL) at `~/Library/Application Support/mem-agent/`,
  10s system / 30s top-40 process cadence, 7-day retention.
- Prediction: damped Holt (ETS(A,Ad,N)) with robust scale, a Page-Hinkley
  regime detector that resets it on sudden shifts, and a Monte-Carlo
  first-passage distribution → `P(critical within 15 min)` + p10/median ETAs
  against a learned per-machine threshold (Autopilot-style decayed histogram).
  Deterministic, no ML — see RESEARCH.md for why that's a considered choice.
- Thrash gauge: PSI-style stall synthesis from swap-in/page-in/compressor
  deltas. Swap-outs alone never alarm (healthy offloading); swap-ins do.
  Gates all aggressive actions.
- Leaks: Theil-Sen slope + Mann-Kendall significance (BH-corrected, 3
  sustained windows) against each app's own learned ceiling
  (p98×1.15 / weekly peak), with a 15-min warmup gate and a
  cache-warming (deceleration) filter. Flags carry MB/h and time-to-exhaustion.
- Action ranking: recovery-per-disruption (SmartLMK) using P(return) from an
  order-3 PPM + frecency + reuse distance, the Iqbal-Horvitz dwell rule,
  lmkd pressure bands, a ≤4-actions/hour budget, and re-fault feedback that
  auto-disables action types users keep undoing.
- Self-evaluation: `memagent backtest` replays the recorded history through
  the new and legacy predictors and scores both against kernel truth.

## Status

- ✅ Phase A — sensors + `snapshot`
- ✅ Phase B — history, anomaly detection, prediction, `stress`
- ✅ Phase C — unix-socket IPC, MCP plugin, `/memory`, launchd install
- ✅ Phase D — deterministic policy validator (default-deny decision table:
  protected list + glob patterns, frontmost app, idle minimum, manageable
  allowlist, pid-reuse guard, already-suspended guard, per-escalation cap),
  reversible actions (SIGSTOP/SIGCONT and docker pause/unpause with auto-revert
  on deadline, on pressure clearing, and on daemon shutdown), autonomous
  escalation (kernel pressure transitions or predicted ETA < 10 min) with
  headless `claude -p` reasoning over a pre-filtered action menu, rate limiting
  + a 3-strike circuit breaker, deterministic fallback when no LLM is
  reachable, and a JSONL audit trail of every proposal/verdict/execution/revert.

Autonomy ships as `suggest`: escalations only ever *propose*; nothing executes
without an explicit `execute` call (the `/memory` flow asks the user first).
Set `autonomy: "auto_reversible"` via `policy_set` to let the daemon
auto-execute reversible actions, or `"off"` to disable even proposals.
The manageable allowlist starts empty — mem-agent touches nothing you haven't
explicitly listed.

Try the pipeline: `memagent propose`, `memagent execute <action-id>`,
`memagent escalate --dry-run` (full drill, executes nothing).

## Chrome tab suspension

The biggest lever on most machines. A minimal MV3 extension
([chrome-extension/](chrome-extension/)) reports the tab inventory every 30s
over Chrome native messaging (`memagent chrome-host` bridges stdio ↔ the
daemon socket) and discards the tabs the daemon approves. Only the URL host
and a truncated title leave the browser, and only to the local daemon.
Discarded tabs stay visible and reload instantly when clicked. Active, pinned,
audible, and recently-used (<5 min) tabs are never touched.

```bash
memagent chrome-install      # registers the native-messaging host
# then once in Chrome: chrome://extensions → Developer mode → Load unpacked → chrome-extension/
memagent chrome-status       # connected within ~30s
```

The `chrome_discard_tabs` action then appears in proposals automatically.

## Menu bar

`memagent menubar-install` puts a live readout in the menu bar (🟢/🟡/🔴 +
estimated available). The menu shows pressure, prediction, top consumers, the
Chrome bridge status, and **Optimize Now** — propose → confirm dialog →
execute, all through the same policy validator. `memagent menubar-uninstall`
removes it.

## LLM escalation

Escalation uses whatever `claude` CLI is on the login-shell PATH, or
`escalation.claude_path` in the policy. Install one with
`npm install -g @anthropic-ai/claude-code`. Without a CLI the daemon falls back
to deterministic proposals — everything still works, just without the written
analysis.

Protocol reference: [schema/ipc.md](schema/ipc.md).
