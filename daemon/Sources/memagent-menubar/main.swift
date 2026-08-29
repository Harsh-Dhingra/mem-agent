import AppKit
import Foundation
import MemAgentCore

/// Menu-bar companion for the memagent daemon: live pressure/avail in the
/// status bar, details + Optimize Now in the menu. Pure socket client — all
/// state lives in the daemon.
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "memagent.menubar.refresh")

    // Last fetched state (main thread only).
    private var stateLine = "connecting…"
    private var predictionLine = ""
    private var topLines: [String] = []
    private var chromeLine = ""
    private var daemonOK = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◌ mem"
        statusItem.menu = menu
        menu.delegate = self
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        refreshQueue.async {
            var title = "◌ mem"
            var state = "daemon not reachable — run `memagent install`"
            var predictionLine = ""
            var topLines: [String] = []
            var chromeLine = ""
            var ok = false
            do {
                let raw = try SocketClient.call(method: "state")
                guard let obj = raw as? [String: Any],
                      let system = obj["system"] as? [String: Any] else {
                    throw SocketClientError.badResponse("state shape")
                }
                ok = true
                let avail = (system["avail_bytes"] as? NSNumber)?.uint64Value ?? 0
                let used = ((system["internal_bytes"] as? NSNumber)?.uint64Value ?? 0)
                    &+ ((system["wired_bytes"] as? NSNumber)?.uint64Value ?? 0)
                    &+ ((system["compressed_bytes"] as? NSNumber)?.uint64Value ?? 0)
                let total = (system["total_bytes"] as? NSNumber)?.uint64Value ?? 0
                let level = system["pressure_level"] as? Int ?? 1
                let dot = level == 1 ? "🟢" : (level == 2 ? "🟡" : "🔴")
                title = "\(dot) \(formatBytes(avail))"
                state = "Used \(formatBytes(used)) of \(formatBytes(total)) — pressure \(level == 1 ? "normal" : level == 2 ? "warn" : "critical")"

                if let p = try SocketClient.call(method: "predict") as? [String: Any] {
                    if let eta = (p["eta_minutes_to_critical"] as? NSNumber)?.doubleValue {
                        predictionLine = String(format: "Critical pressure in ~%.0f min (%@)",
                                                eta, p["confidence"] as? String ?? "low")
                    } else {
                        predictionLine = "No critical pressure expected on current trend"
                    }
                }
                if let groups = try SocketClient.call(method: "top", params: ["n": 5]) as? [[String: Any]] {
                    topLines = groups.map { g in
                        let bytes = (g["footprint_bytes"] as? NSNumber)?.uint64Value ?? 0
                        return "\(formatBytes(bytes))  \(g["name"] as? String ?? "?")"
                    }
                }
                if let c = try SocketClient.call(method: "chrome_status") as? [String: Any] {
                    let connected = c["connected"] as? Bool ?? false
                    let discardable = c["discardable_count"] as? Int ?? 0
                    chromeLine = connected
                        ? "Chrome bridge: connected, \(discardable) discardable tabs"
                        : "Chrome bridge: not connected"
                }
            } catch {
                // leave defaults
            }
            DispatchQueue.main.async {
                self.daemonOK = ok
                self.stateLine = state
                self.predictionLine = predictionLine
                self.topLines = topLines
                self.chromeLine = chromeLine
                self.statusItem.button?.title = title
            }
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(disabled(stateLine))
        if !predictionLine.isEmpty { menu.addItem(disabled(predictionLine)) }
        if !chromeLine.isEmpty { menu.addItem(disabled(chromeLine)) }
        if !topLines.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("Top consumers"))
            for line in topLines { menu.addItem(disabled("   " + line)) }
        }
        menu.addItem(.separator())
        let optimize = NSMenuItem(title: "Optimize Now…", action: #selector(optimizeNow), keyEquivalent: "o")
        optimize.target = self
        optimize.isEnabled = daemonOK
        menu.addItem(optimize)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit mem-agent menu bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func optimizeNow() {
        refreshQueue.async {
            let proposal: [String: Any]
            do {
                guard let p = try SocketClient.call(
                    method: "propose", params: ["use_llm": false, "source": "menubar"],
                    timeoutSeconds: 15) as? [String: Any] else { return }
                proposal = p
            } catch {
                DispatchQueue.main.async { self.alert(text: "Proposal failed: \(error)") }
                return
            }
            let verdicts = (proposal["verdicts"] as? [[String: Any]] ?? [])
            let allowed = verdicts.filter { ($0["allowed"] as? Bool) == true }
            let actionable = allowed.filter {
                (($0["action"] as? [String: Any])?["action"] as? String) != "report"
            }
            let reports = allowed.filter {
                (($0["action"] as? [String: Any])?["action"] as? String) == "report"
            }

            DispatchQueue.main.async {
                var lines: [String] = []
                for v in actionable {
                    let a = v["action"] as? [String: Any] ?? [:]
                    let mb = (a["expected_mb_freed"] as? NSNumber)?.doubleValue ?? 0
                    lines.append("• \(a["action"] as? String ?? "?") \(a["target_name"] as? String ?? "") (~\(Int(mb)) MB)")
                }
                for r in reports {
                    let a = r["action"] as? [String: Any] ?? [:]
                    lines.append("ℹ︎ \(a["reason"] as? String ?? "")")
                }
                guard !actionable.isEmpty else {
                    self.alert(text: lines.isEmpty
                               ? "Nothing to do — no policy-allowed actions right now."
                               : "No executable actions.\n\n" + lines.joined(separator: "\n"))
                    return
                }
                let confirm = NSAlert()
                confirm.messageText = "Optimize memory?"
                confirm.informativeText = lines.joined(separator: "\n")
                confirm.addButton(withTitle: "Optimize")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }

                self.refreshQueue.async {
                    var results: [String] = []
                    for v in actionable {
                        guard let id = v["id"] as? String else { continue }
                        if let r = try? SocketClient.call(method: "execute",
                                                          params: ["action_id": id]) as? [String: Any] {
                            results.append(r["detail"] as? String ?? "done")
                        }
                    }
                    DispatchQueue.main.async {
                        self.alert(text: results.isEmpty ? "Nothing executed."
                                   : results.joined(separator: "\n"))
                        self.refresh()
                    }
                }
            }
        }
    }

    private func alert(text: String) {
        let a = NSAlert()
        a.messageText = "mem-agent"
        a.informativeText = text
        a.runModal()
    }
}

extension MenuBarApp: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MenuBarApp()
app.delegate = delegate
app.run()
