import Foundation

/// App 和命令行之间的通信：unix socket，一行一个 JSON。
public enum IPC {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        return addr
    }

    static func writeLine(_ fd: Int32, _ obj: [String: Any]) -> Bool {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        d.append(0x0A)
        return d.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < d.count {
                let n = write(fd, p.baseAddress! + off, d.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    static func readLine(_ fd: Int32, buffer: inout Data) -> [String: Any]? {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<i)
                buffer.removeSubrange(buffer.startIndex...i)
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { return o }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// 命令行调用 App。App 没开时返回 nil。
    public static func request(_ obj: [String: Any], timeout: TimeInterval = 15) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = address(ReachPaths.socket) else { return nil }
        defer { close(fd) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard writeLine(fd, obj) else { return nil }
        var buf = Data()
        return readLine(fd, buffer: &buf)
    }
}

public final class IPCServer {
    public typealias Handler = (_ request: [String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Void
    private let handler: Handler
    private var fd: Int32 = -1

    public init(handler: @escaping Handler) { self.handler = handler }

    public func start() -> Bool {
        let path = ReachPaths.socket
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = IPC.address(path) else { return false }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return false }
        chmod(path, 0o600) // 只有自己的进程能连
        guard listen(fd, 16) == 0 else { return false }
        signal(SIGPIPE, SIG_IGN)
        let lfd = fd
        Thread.detachNewThread { [handler] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { if errno == EINTR { continue } else { break } }
                Thread.detachNewThread {
                    var buf = Data()
                    while let req = IPC.readLine(c, buffer: &buf) {
                        let sem = DispatchSemaphore(value: 0)
                        var answer: [String: Any] = [:]
                        DispatchQueue.main.async {
                            handler(req) { r in answer = r; sem.signal() }
                        }
                        sem.wait()
                        if !IPC.writeLine(c, answer) { break }
                    }
                    close(c)
                }
            }
        }
        return true
    }

    public func stop() { if fd >= 0 { close(fd); unlink(ReachPaths.socket) } }
}
