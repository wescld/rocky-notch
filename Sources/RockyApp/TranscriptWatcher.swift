import Foundation
import RockyCore

/// Tails session transcript JSONL files and reports the latest action.
/// Secondary data source only (spec §3.5): hooks own the state machine;
/// this enriches the UI. All failures are silent.
final class TranscriptWatcher {
    private final class Watch {
        let fd: Int32
        let source: DispatchSourceFileSystemObject
        var offset: UInt64

        init(fd: Int32, source: DispatchSourceFileSystemObject, offset: UInt64) {
            self.fd = fd
            self.source = source
            self.offset = offset
        }
    }

    private let queue = DispatchQueue(label: "app.vibenotch.transcripts", qos: .utility)
    private var watches: [String: Watch] = [:]

    /// Called on main with (sessionId, update).
    var onUpdate: ((String, TranscriptTail.Update) -> Void)?

    func watch(sessionId: String, path: String) {
        queue.async { [weak self] in
            guard let self, self.watches[sessionId] == nil else { return }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return }

            // Start from the current end: only new activity matters.
            let size = lseek(fd, 0, SEEK_END)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: self.queue
            )
            let watch = Watch(fd: fd, source: source, offset: UInt64(max(size, 0)))
            source.setEventHandler { [weak self] in
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self?.stopLocked(sessionId: sessionId)
                } else {
                    self?.readNew(sessionId: sessionId)
                }
            }
            source.setCancelHandler { close(fd) }
            self.watches[sessionId] = watch
            source.resume()
        }
    }

    func unwatch(sessionId: String) {
        queue.async { [weak self] in
            self?.stopLocked(sessionId: sessionId)
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(self.watches.keys) {
                self.stopLocked(sessionId: id)
            }
        }
    }

    private func stopLocked(sessionId: String) {
        watches.removeValue(forKey: sessionId)?.source.cancel()
    }

    private func readNew(sessionId: String) {
        guard let watch = watches[sessionId] else { return }
        let size = lseek(watch.fd, 0, SEEK_END)
        guard size > 0, UInt64(size) > watch.offset else { return }

        let length = min(UInt64(size) - watch.offset, 1 << 20)
        var buffer = Data(count: Int(length))
        let read = buffer.withUnsafeMutableBytes { ptr in
            pread(watch.fd, ptr.baseAddress, Int(length), off_t(watch.offset))
        }
        guard read > 0 else { return }
        buffer.removeSubrange(read..<buffer.count)

        // Only advance past the last complete line; a partial tail line is
        // re-read on the next event.
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return }
        watch.offset += UInt64(lastNewline + 1)

        let update = TranscriptTail.scan(buffer.subdata(in: 0..<(lastNewline + 1)))
        if update.lastAction != nil || update.tokens > 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(sessionId, update)
            }
        }
    }
}
