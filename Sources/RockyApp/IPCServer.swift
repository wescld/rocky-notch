import Foundation
import RockyCore

/// Unix-domain-socket server for rocky-hook connections.
///
/// Threading: all socket work happens on `queue`; envelopes are delivered to
/// `onEnvelope` on the main queue. Replies come back via `reply(_:to:)`.
final class IPCServer {
    enum StartError: Error {
        case anotherInstanceRunning
        case socketFailed(String)
    }

    private let queue = DispatchQueue(label: "app.vibenotch.ipc")
    private let socketPath: String
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Connections still waiting for a decision, keyed by requestId.
    private var pendingConnections: [String: Connection] = [:]
    private var connections: Set<Connection> = []

    /// Called on main for every decoded envelope.
    var onEnvelope: ((HookEnvelope) -> Void)?
    /// Called on main when a pending request dies without a decision
    /// (connection dropped). Timeouts are the hub's job, not the server's.
    var onPendingDropped: ((String) -> Void)?

    init(socketPath: String = IPC.socketPath()) {
        self.socketPath = socketPath
    }

    func start() throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: socketPath) {
            if Self.isSocketAlive(path: socketPath) {
                throw StartError.anotherInstanceRunning
            }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socketFailed("socket()") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw StartError.socketFailed("path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw StartError.socketFailed("bind/listen errno=\(errno)")
        }
        chmod(socketPath, 0o600)
        listenFd = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for connection in connections { connection.close() }
            connections.removeAll()
            pendingConnections.removeAll()
            if listenFd >= 0 { close(listenFd) }
            listenFd = -1
            unlink(socketPath)
        }
    }

    /// Sends the decision to the waiting hook (if still connected).
    func reply(_ decision: Decision, to requestId: String) {
        queue.async {
            guard let connection = self.pendingConnections.removeValue(forKey: requestId) else {
                return
            }
            let message = DecisionMessage(requestId: requestId, decision: decision)
            if let line = try? NDJSON.encodeLine(message) {
                connection.write(line)
            }
            connection.close()
            self.connections.remove(connection)
        }
    }

    private static func isSocketAlive(path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private func acceptConnection() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        let connection = Connection(fd: fd, queue: queue)
        connections.insert(connection)
        connection.onLine = { [weak self, weak connection] line in
            guard let self, let connection else { return }
            self.handle(line: line, from: connection)
        }
        connection.onClosed = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.connections.remove(connection)
            let dropped = self.pendingConnections.filter { $0.value === connection }
            for (requestId, _) in dropped {
                self.pendingConnections[requestId] = nil
                DispatchQueue.main.async { self.onPendingDropped?(requestId) }
            }
        }
        connection.start()
    }

    private func handle(line: Data, from connection: Connection) {
        guard let envelope = try? NDJSON.decode(HookEnvelope.self, from: line) else {
            connection.close()
            connections.remove(connection)
            return
        }
        if envelope.event.kind == .permissionRequest {
            pendingConnections[envelope.requestId] = connection
        } else {
            connection.close()
            connections.remove(connection)
        }
        DispatchQueue.main.async { self.onEnvelope?(envelope) }
    }
}

/// One accepted hook connection; reads NDJSON lines.
private final class Connection: Hashable {
    private let fd: Int32
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var isOpen = true

    var onLine: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        readSource = source
    }

    func start() {
        readSource?.resume()
    }

    func write(_ data: Data) {
        guard isOpen else { return }
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        readSource?.cancel()
        readSource = nil
        Darwin.close(fd)
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else {
            close()
            onClosed?()
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine?(line) }
        }
        if buffer.count > 1 << 20 {
            close()
            onClosed?()
        }
    }

    static func == (lhs: Connection, rhs: Connection) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
