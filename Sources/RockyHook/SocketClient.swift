import Foundation

/// Blocking Unix-domain-socket client with hard deadlines. Every failure is
/// reported as nil/false so the caller can fail open.
struct SocketClient {
    let fd: Int32

    /// Connects with a strict deadline (non-blocking connect + poll).
    static func connect(path: String, timeoutMs: Int32) -> SocketClient? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            dest.copyBytes(from: pathBytes)
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) == 1 else {
                close(fd)
                return nil
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard soError == 0 else {
                close(fd)
                return nil
            }
        }

        // Back to blocking for the write/read phase; deadlines use poll.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        return SocketClient(fd: fd)
    }

    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Reads until the first newline or the deadline; nil on any failure.
    func readLine(deadline: Date) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, remaining) == 1 else { return nil }
            let n = read(fd, &byte, 1)
            guard n == 1 else { return nil }
            if byte == 0x0A { return buffer }
            buffer.append(byte)
            if buffer.count > 1 << 20 { return nil }
        }
    }

    func closeSocket() {
        close(fd)
    }
}
