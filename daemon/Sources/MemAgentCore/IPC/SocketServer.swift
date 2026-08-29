import Darwin
import Foundation

/// Unix-domain-socket server speaking newline-delimited JSON. One thread per
/// connection — traffic is a handful of requests per minute at most.
public final class SocketServer {
    private let path: String
    private let router: Router
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?

    public init(path: String, router: Router) {
        self.path = path
        self.router = router
    }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        listenFD = fd

        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        precondition(pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path),
                     "socket path too long: \(path)")
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.copyBytes(from: pathBytes)
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, size)
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno)!)
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno)!)
        }

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "memagent.socket.accept"
        thread.start()
        acceptThread = thread
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else {
                if errno == EBADF { return }  // stopped
                continue
            }
            let thread = Thread { [weak self] in self?.serve(conn: conn) }
            thread.name = "memagent.socket.conn"
            thread.start()
        }
    }

    private func serve(conn: Int32) {
        defer { close(conn) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(conn, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty else { continue }
                let response = router.handle(line: line)
                response.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let written = write(conn, raw.baseAddress!.advanced(by: off), raw.count - off)
                        guard written > 0 else { return }
                        off += written
                    }
                }
            }
        }
    }
}
