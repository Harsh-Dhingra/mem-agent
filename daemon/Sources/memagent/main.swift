import Foundation
import MemAgentCore

let usage = """
memagent \(memAgentVersion) — macOS memory-management agent

USAGE: memagent <command> [options]

COMMANDS:
  snapshot [--json]        One-shot system + per-process memory snapshot
  top [-n N] [--json]      Top memory consumers (grouped by app) via daemon, local fallback
  predict [--json]         Time-to-pressure prediction (requires running daemon)
  anomalies [--json]       Active per-process growth anomalies (requires running daemon)
  history <pid> [--json]   Recent footprint history for a pid (requires running daemon)
  run                      Run the daemon in the foreground
  stress --mb N [--rate MB/s] [--hold SECS]   Allocate memory for testing
  propose [--llm] [--json] Ask the daemon for a policy-validated recovery plan
  execute <action-id>      Execute one action from the last proposal (re-validated)
  escalate --dry-run       Full escalation drill: prompt → claude -p → validator verdicts, executes nothing
  backtest [--days N]      Replay recorded history through the new + legacy predictors
  install                  Install binary + launchd agent (com.memagent.daemon)
  uninstall                Stop and remove the launchd agent
  chrome-install           Register the Chrome native-messaging host + print extension steps
  chrome-status            Chrome tab-bridge status (connected, tab counts)
  menubar-install          Install the menu-bar app as a login launchd agent
  menubar-uninstall        Remove the menu-bar launchd agent
  status                   Daemon / launchd / socket health
  logs [-n N]              Tail the daemon log
  policy                   Print the active policy JSON
  version                  Print version
"""

let args = Array(CommandLine.arguments.dropFirst())

func hasFlag(_ name: String) -> Bool { args.contains(name) }

func optionValue(_ name: String) -> String? {
    guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

guard let command = args.first else {
    print(usage)
    exit(1)
}

do {
    switch command {
    case "snapshot":
        try SnapshotCommand.run(json: hasFlag("--json"))
    case "top":
        let n = optionValue("-n").flatMap(Int.init) ?? 10
        try ClientCommands.top(n: n, json: hasFlag("--json"))
    case "predict":
        try ClientCommands.predict(json: hasFlag("--json"))
    case "anomalies":
        try ClientCommands.anomalies(json: hasFlag("--json"))
    case "history":
        guard args.count >= 2, let pid = Int32(args[1]) else {
            print("usage: memagent history <pid>"); exit(1)
        }
        try ClientCommands.history(pid: pid, json: hasFlag("--json"))
    case "run":
        try Daemon().run()
    case "stress":
        guard let mb = optionValue("--mb").flatMap(Int.init) else {
            print("usage: memagent stress --mb N [--rate MB/s] [--hold SECS]"); exit(1)
        }
        StressCommand.run(mb: mb,
                          ratePerSec: optionValue("--rate").flatMap(Int.init) ?? 512,
                          holdSeconds: optionValue("--hold").flatMap(Int.init) ?? 60)
    case "propose":
        try ClientCommands.propose(useLLM: hasFlag("--llm"), source: "cli", json: hasFlag("--json"))
    case "execute":
        guard args.count >= 2 else { print("usage: memagent execute <action-id>"); exit(1) }
        try ClientCommands.execute(actionID: args[1])
    case "escalate":
        guard hasFlag("--dry-run") else {
            print("usage: memagent escalate --dry-run   (escalations otherwise fire autonomously)")
            exit(1)
        }
        try ClientCommands.propose(useLLM: true, source: "dry_run", json: hasFlag("--json"))
    case "install":
        try InstallCommand.install()
    case "uninstall":
        try InstallCommand.uninstall()
    case "chrome-host":
        ChromeHostCommand.run()
    case "chrome-install":
        try ChromeInstallCommand.install(
            extensionDir: optionValue("--extension-dir")
                ?? Paths.home.appendingPathComponent("mem-agent/chrome-extension").path)
    case "chrome-status":
        try ChromeInstallCommand.status()
    case "menubar-install":
        try InstallCommand.installMenuBar()
    case "menubar-uninstall":
        try InstallCommand.uninstallMenuBar()
    case "status":
        InstallCommand.status()
    case "logs":
        InstallCommand.logs(lines: optionValue("-n").flatMap(Int.init) ?? 50)
    case "backtest":
        let days = optionValue("--days").flatMap(Double.init) ?? 7
        let db = try Database(path: Paths.database.path)
        let series = try db.systemSeries(since: Date().timeIntervalSince1970 - days * 86400)
        let total = Double(try SystemStats.totalMemory())
        print(Backtest.run(series: series, totalBytes: total).rendered())
    case "policy":
        print(try Policy.loadOrCreateDefault().prettyJSON())
    case "version":
        print(memAgentVersion)
    case "help", "--help", "-h":
        print(usage)
    default:
        print("unknown command: \(command)\n")
        print(usage)
        exit(1)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
