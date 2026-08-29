---
description: Live memory report from the mem-agent daemon — state, prediction, anomalies, and safe recovery suggestions
---

Produce a memory health report for this Mac using the memagent MCP tools, then offer next steps.

1. Call `memory_state`, `predict`, `growth_anomalies`, and `chrome_status` (in parallel). If any tool reports the daemon is not running, say so and tell the user to run `memagent install` (persistent) or `memagent run` (foreground) — then stop.

2. Render a compact report:
   - Headline: used / total, kernel pressure level, estimated available. Format bytes as GB/MB — never raw numbers.
   - Prediction: if an ETA to warn/critical exists, lead with it ("critical pressure predicted in ~N min, confidence X") and list the drivers. If no stable downward trend, say no pressure is expected on the current trend.
   - Anomalies: any process growing far above its baseline, with pid, current footprint, and growth. If none, one line: no leaks detected.
   - Top consumers: call `top_consumers` (n=8) and show a short table grouped by app.

3. If pressure is warn/critical, an ETA exists, or anomalies are active, offer to help:
   - Call `propose_plan` (leave use_llm false — you are the reasoner). Show each verdict: ✓/✗, action, target, estimated recovery, and the deny reason for ✗ ones. Note the total estimated recovery.
   - If the allowed actions are empty (common when the manageable allowlist is empty), suggest the 2–3 highest-impact manual steps grounded in the actual data (e.g. "Chrome's renderers hold 34 GB — closing tabs would recover the most"), and mention that `policy_set` can allowlist specific apps for automatic management.
   - Only call `execute_action` after the user explicitly confirms the specific action in this conversation. Reversible actions auto-revert (deadline or when pressure clears); say so.

4. Keep the whole report under ~25 lines. No preamble.

$ARGUMENTS
