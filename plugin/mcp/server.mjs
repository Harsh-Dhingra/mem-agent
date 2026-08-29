#!/usr/bin/env node
// MCP stdio server for the memagent daemon. Stateless proxy: every tool call
// becomes one request over the daemon's unix socket.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { callDaemon } from "./socket-client.mjs";

const server = new McpServer({ name: "memagent", version: "0.1.0" });

function proxyTool(name, description, paramsShape, buildCall) {
  server.tool(name, description, paramsShape, async (args) => {
    try {
      const { method, params } = buildCall(args ?? {});
      const result = await callDaemon(method, params);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    } catch (err) {
      return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
    }
  });
}

proxyTool(
  "memory_state",
  "Current system memory state: totals, free/inactive/wired/compressed, swap, kernel pressure level (normal/warn/critical), estimated available bytes, and daemon health.",
  {},
  () => ({ method: "state", params: {} }),
);

proxyTool(
  "top_consumers",
  "Top memory consumers grouped by app name (helper processes rolled up), sorted by phys_footprint. Footprints match Activity Monitor's Memory column.",
  { n: z.number().int().min(1).max(50).optional().describe("How many groups to return (default 10)") },
  ({ n }) => ({ method: "top", params: { n: n ?? 10 } }),
);

proxyTool(
  "predict",
  "Deterministic time-to-pressure prediction: EWMA trend of available memory, ETA in minutes to warn/critical pressure (null if no stable downward trend), confidence, swap-in rate, and the drivers behind the trend.",
  {},
  () => ({ method: "predict", params: {} }),
);

proxyTool(
  "growth_anomalies",
  "Processes whose memory footprint is growing abnormally: short-term average far above their 30-minute baseline, sustained over several sweeps. Useful for spotting leaks (e.g. a language server growing 400MB → 1.4GB).",
  {},
  () => ({ method: "anomalies", params: {} }),
);

proxyTool(
  "process_history",
  "Footprint history for one pid from the daemon's SQLite store (the daemon records the top 40 consumers every 30s).",
  {
    pid: z.number().int().describe("Process id"),
    minutes: z.number().min(1).max(1440).optional().describe("Window in minutes (default 30)"),
  },
  ({ pid, minutes }) => ({ method: "history", params: { pid, minutes: minutes ?? 30 } }),
);

proxyTool(
  "policy_get",
  "The active mem-agent policy: autonomy level (off/suggest/auto_reversible), protected apps, manageable allowlist, idle thresholds, and escalation limits.",
  {},
  () => ({ method: "policy_get", params: {} }),
);

proxyTool(
  "propose_plan",
  "Ask the daemon for a policy-validated memory-recovery plan. Each returned verdict has an id, the proposed action (sigstop_process/docker_pause/report), allowed true/false, and the deny reason if not. Nothing is executed. In-session you are the reasoner: leave use_llm false.",
  { use_llm: z.boolean().optional().describe("Also invoke the daemon's headless claude -p reasoner (slow; for drills). Default false: deterministic proposal.") },
  ({ use_llm }) => ({ method: "propose", params: { use_llm: use_llm ?? false, source: "mcp" } }),
);

proxyTool(
  "execute_action",
  "Execute one allowed action id from the latest propose_plan result. The daemon re-validates against policy at execution time (frontmost/idle/protected checks rerun) and reversible actions get an auto-revert deadline. Only call this after the user explicitly confirmed the specific action in this conversation.",
  { action_id: z.string().describe("Action id from propose_plan") },
  ({ action_id }) => ({ method: "execute", params: { action_id } }),
);

proxyTool(
  "policy_set",
  "Update the mem-agent policy: autonomy level (off/suggest/auto_reversible) and add/remove entries in the manageable and protected app lists. Only change policy when the user explicitly asks.",
  {
    autonomy: z.enum(["off", "suggest", "auto_reversible"]).optional(),
    add_manageable: z.array(z.string()).optional(),
    remove_manageable: z.array(z.string()).optional(),
    add_protected: z.array(z.string()).optional(),
    remove_protected: z.array(z.string()).optional(),
  },
  (args) => ({ method: "policy_set", params: args }),
);

proxyTool(
  "chrome_status",
  "Status of the Chrome tab bridge: whether the mem-agent extension is connected, total tabs, and how many inactive tabs are currently discardable (the biggest memory lever when Chrome is the top consumer).",
  {},
  () => ({ method: "chrome_status", params: {} }),
);

proxyTool(
  "audit_tail",
  "Tail of the daemon's audit log: escalations, validator verdicts, executed/reverted actions.",
  { n: z.number().int().min(1).max(500).optional().describe("Lines (default 50)") },
  ({ n }) => ({ method: "audit_tail", params: { n: n ?? 50 } }),
);

const transport = new StdioServerTransport();
await server.connect(transport);
