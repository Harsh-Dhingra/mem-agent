import Dispatch
import Foundation
import MemAgentCore

final class Daemon {
    func run() throws {
        try Paths.ensureDirectories()
        let db = try Database(path: Paths.database.path)
        let engine = Engine(db: db)
        let server = SocketServer(path: Paths.socket.path, router: Router(engine: engine))

        engine.log("memagent \(memAgentVersion) starting (pid \(getpid()))")
        engine.start()
        try server.start()
        engine.log("listening on \(Paths.socket.path)")

        // Clean shutdown on SIGINT/SIGTERM.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                engine.log("shutting down (signal \(sig))")
                engine.shutdown()  // SIGCONT anything we suspended
                server.stop()
                exit(0)
            }
            src.resume()
            return src
        }
        _ = signals

        dispatchMain()
    }
}
