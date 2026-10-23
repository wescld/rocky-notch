import AppKit
import RockyCore

/// Directory watches survive atomic config replacement. A cheap periodic scan
/// and application activation cover missing directories and missed events.
@MainActor
final class PermissionBrokerWatcher {
    var onChange: (([PermissionBrokerFinding], [PermissionBrokerFinding]) -> Void)?
    var projects: () -> [String] = { [] }
    private var monitor = PermissionBrokerMonitor()
    private var watches: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: Timer?
    private var activation: NSObjectProtocol?
    private var debounce: DispatchWorkItem?

    func start() {
        monitor = PermissionBrokerMonitor(dismissedKeys: Preferences.dismissedBrokerKeys)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        debounce?.cancel()
        watches.values.forEach { $0.cancel() }
        watches.removeAll()
    }

    func dismiss(_ findings: [PermissionBrokerFinding]) {
        monitor.dismiss(findings)
        Preferences.dismissedBrokerKeys = monitor.dismissedKeys
    }

    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func refresh() {
        let sources = PermissionBrokerSource.defaults(
            home: NSHomeDirectory(), projects: projects(), environment: ProcessInfo.processInfo.environment
        )
        let previouslyDismissed = monitor.dismissedKeys
        let appeared = monitor.check(sources: sources)
        if monitor.dismissedKeys != previouslyDismissed {
            Preferences.dismissedBrokerKeys = monitor.dismissedKeys
        }
        onChange?(Array(monitor.current).sorted { $0.path < $1.path }, appeared)
        updateWatches(sources)
        if monitor.needsConfirmation { schedule() }
    }

    private func updateWatches(_ sources: [PermissionBrokerSource]) {
        var directories: Set<String> = []
        for source in sources {
            var directory = (source.path as NSString).deletingLastPathComponent
            var isDirectory: ObjCBool = false
            while !FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
                || !isDirectory.boolValue {
                let parent = (directory as NSString).deletingLastPathComponent
                if parent == directory { break }
                directory = parent
            }
            directories.insert(directory)
        }
        for path in Array(watches.keys) where !directories.contains(path) {
            watches.removeValue(forKey: path)?.cancel()
        }
        for path in directories where watches[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let watch = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main
            )
            watch.setEventHandler { [weak self, weak watch] in
                Task { @MainActor in
                    if watch?.data.contains(.delete) == true || watch?.data.contains(.rename) == true {
                        self?.watches.removeValue(forKey: path)?.cancel()
                    }
                    self?.schedule()
                }
            }
            watch.setCancelHandler { close(descriptor) }
            watches[path] = watch
            watch.resume()
        }
    }
}
