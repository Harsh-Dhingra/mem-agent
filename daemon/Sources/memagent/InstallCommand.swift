import Darwin
import Foundation
import MemAgentCore

enum InstallCommand {
    static let label = "com.memagent.daemon"

    static func install() throws {
        try Paths.ensureDirectories()
        let fm = FileManager.default

        // 1. Copy this binary to a stable location launchd can point at.
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dest = Paths.installedBinary
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: selfPath, to: dest)

        // 2. Write the launchd plist. launchd agents don't inherit the login
        //    shell env, so PATH is pinned explicitly.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(dest.path)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>ProcessType</key><string>Background</string>
            <key>LowPriorityBackgroundIO</key><true/>
            <key>EnvironmentVariables</key>
            <dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string></dict>
            <key>StandardOutPath</key><string>\(Paths.logsDir.path)/daemon.out.log</string>
            <key>StandardErrorPath</key><string>\(Paths.logsDir.path)/daemon.err.log</string>
        </dict>
        </plist>
        """
        try plist.write(to: Paths.launchAgentPlist, atomically: true, encoding: .utf8)

        // 3. (Re)load.
        let uid = getuid()
        _ = shell("launchctl", "bootout", "gui/\(uid)/\(label)")  // ok to fail if not loaded
        let (code, out) = shell("launchctl", "bootstrap", "gui/\(uid)", Paths.launchAgentPlist.path)
        guard code == 0 else {
            throw NSError(domain: "memagent", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(out)"])
        }
        _ = shell("launchctl", "kickstart", "gui/\(uid)/\(label)")
        print("installed: \(dest.path)")
        print("launchd agent \(label) loaded; logs in \(Paths.logsDir.path)")
        Thread.sleep(forTimeInterval: 1.0)
        status()
    }

    static func uninstall() throws {
        _ = shell("launchctl", "bootout", "gui/\(getuid())/\(label)")
        try? FileManager.default.removeItem(at: Paths.launchAgentPlist)
        print("launchd agent \(label) removed (binary left at \(Paths.installedBinary.path))")
    }

    static func status() {
        let (code, out) = shell("launchctl", "print", "gui/\(getuid())/\(label)")
        if code == 0 {
            let state = out.split(separator: "\n")
                .first { $0.contains("state =") }?
                .trimmingCharacters(in: .whitespaces) ?? "state = unknown"
            let pid = out.split(separator: "\n")
                .first { $0.contains("pid =") }?
                .trimmingCharacters(in: .whitespaces)
            print("launchd: loaded (\(state)\(pid.map { ", \($0)" } ?? ""))")
        } else {
            print("launchd: not loaded")
        }
        do {
            let pong = try SocketClient.call(method: "ping")
            if let obj = pong as? [String: Any], obj["ok"] as? Bool == true {
                print("socket:  responding (version \(obj["version"] as? String ?? "?"))")
            }
        } catch {
            print("socket:  \(error)")
        }
    }

    static let menuBarLabel = "com.memagent.menubar"

    static var menuBarPlist: URL {
        Paths.home.appendingPathComponent("Library/LaunchAgents/\(menuBarLabel).plist")
    }

    static func installMenuBar() throws {
        let fm = FileManager.default
        // The menubar binary is built alongside this one.
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let source = selfPath.deletingLastPathComponent().appendingPathComponent("memagent-menubar")
        guard fm.isExecutableFile(atPath: source.path) else {
            throw NSError(domain: "memagent", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "memagent-menubar not found next to \(selfPath.path) — run from the build directory (`swift build -c release` first)"])
        }
        let dest = Paths.home.appendingPathComponent(".local/bin/memagent-menubar")
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(menuBarLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(dest.path)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
        </dict>
        </plist>
        """
        try plist.write(to: menuBarPlist, atomically: true, encoding: .utf8)
        let uid = getuid()
        _ = shell("launchctl", "bootout", "gui/\(uid)/\(menuBarLabel)")
        let (code, out) = shell("launchctl", "bootstrap", "gui/\(uid)", menuBarPlist.path)
        guard code == 0 else {
            throw NSError(domain: "memagent", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(out)"])
        }
        print("menu-bar app installed and started (look for the 🟢/🟡/🔴 avail readout)")
    }

    static func uninstallMenuBar() throws {
        _ = shell("launchctl", "bootout", "gui/\(getuid())/\(menuBarLabel)")
        try? FileManager.default.removeItem(at: menuBarPlist)
        print("menu-bar launchd agent removed")
    }

    static func logs(lines: Int) {
        let path = Paths.logsDir.appendingPathComponent("daemon.out.log").path
        let (_, out) = shell("/usr/bin/tail", "-n", "\(lines)", path)
        print(out)
    }

    @discardableResult
    static func shell(_ args: String...) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: args[0].hasPrefix("/") ? args[0] : "/bin/launchctl")
        if !args[0].hasPrefix("/") {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = Array(args)
        } else {
            task.arguments = Array(args.dropFirst())
        }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
