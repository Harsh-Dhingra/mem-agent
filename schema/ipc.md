# memagent IPC protocol

Transport: unix domain socket at `~/Library/Application Support/mem-agent/memagent.sock`
(mode 0600). Newline-delimited JSON, one request per line:

```json
{"id": 1, "method": "state", "params": {}}
```

Responses (one line each):

```json
{"id": 1, "result": { ... }}
{"id": 1, "error": {"code": "unknown_method", "message": "..."}}
```

All result keys are snake_case. Byte quantities are raw bytes; timestamps are
epoch seconds (float). The Swift `Codable` DTOs in
`daemon/Sources/MemAgentCore/Model.swift` are the source of truth for shapes.

## Methods

| method | params | result |
|---|---|---|
| `ping` | – | `{ok, version}` |
| `state` | – | `{system: SystemSnapshot, daemon: {version, pid, uptime_seconds, rss_bytes}}` |
| `top` | `{n?: int=10}` | `[{name, process_count, footprint_bytes, pids}]` grouped by app name, sorted desc |
| `predict` | – | `{eta_minutes_to_warn?, eta_minutes_to_critical?, confidence, slope_bytes_per_sec, avail_bytes, swap_in_rate_pages_per_sec, drivers}` |
| `anomalies` | – | `[{pid, name, footprint_bytes, short_ewma_bytes, long_ewma_bytes, growth_bytes, first_detected_ts}]` |
| `history` | `{pid: int, minutes?: num=30}` | `[ProcessSample]` (daemon stores top 40 consumers every 30s) |
| `policy_get` | – | Policy JSON (see `~/.config/mem-agent/policy.json`) |
| `audit_tail` | `{n?: int=50}` | `{lines: [string]}` |
| `propose` | `{use_llm?: bool=false, source?: string}` | `{source: "llm"\|"deterministic", analysis?, confidence?, verdicts: [ActionVerdict], escalation_health, estimated_recovery_mb}`. Blocks up to the escalation timeout when `use_llm` is set. Replaces any previously pending action ids. |
| `execute` | `{action_id}` | `{id, executed, detail, auto_revert_at?}`. Re-validates against a fresh context before executing; reversible actions get an auto-revert deadline. |
| `policy_set` | `{autonomy?, add_manageable?, remove_manageable?, add_protected?, remove_protected?}` | updated Policy JSON |
| `chrome_sync` | `{tabs: [{id, active, audible, pinned, discarded, last_accessed (ms), url_host?, title?}]}` | `{discard_tab_ids: [int]}` — from the native-messaging host: stores the inventory, returns and clears queued discards |
| `chrome_status` | – | `{connected, tab_count, discardable_count, last_sync_ts?, pending_discards}` |

## ActionVerdict

`{id, action: {action, target_pid, target_name, reason, expected_mb_freed?}, allowed, verdict}`
— `action.action` ∈ `sigstop_process` \| `docker_pause` \| `report`; `verdict` is
`"allowed"` or a `denied: …` reason from the validator decision table
(protected list, glob patterns, frontmost app, idle < minimum, not in the
manageable allowlist, pid dead or reused, already suspended, docker absent,
autonomy off, per-escalation cap).

## SystemSnapshot fields

`ts, total_bytes, free_bytes, active_bytes, inactive_bytes, wired_bytes,
compressed_bytes, purgeable_bytes, external_bytes, internal_bytes,
swap_total_bytes, swap_used_bytes, swap_ins, swap_outs, page_ins, page_outs,
compressions, pressure_level, avail_bytes`

- `pressure_level`: raw `kern.memorystatus_vm_pressure_level` — 1 normal, 2 warn, 4 critical.
- `avail_bytes`: `free + purgeable + inactive × 0.5` — the series the predictor trends.
- `swap_ins`/`swap_outs`: cumulative page counts since boot.

## Error codes

`bad_request`, `unknown_method`, `not_implemented`, `internal`

## Quick test

```bash
printf '{"id":1,"method":"state"}\n' | nc -U ~/Library/Application\ Support/mem-agent/memagent.sock
```
