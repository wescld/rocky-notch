import Foundation

/// On-disk snapshot of live sessions so Rocky can restore after a relaunch.
public struct PersistedSession: Codable, Equatable, Sendable {
    public var id: String
    public var agent: String
    public var cwd: String?
    public var status: String
    public var lastEventAt: Date
    public var title: String?
    public var model: String?
    public var terminalAppPid: Int32?
    public var agentProcessPid: Int32?
    public var jumpTarget: JumpTarget?
    public var transcriptPath: String?
    public var lastAction: String?
    public var tokens: Int
    public var activeSeconds: TimeInterval
    public var task: String?

    public init(from session: AgentSession) {
        id = session.id
        agent = session.agent
        cwd = session.cwd
        status = Self.encodeStatus(session.status)
        lastEventAt = session.lastEventAt
        title = session.title
        model = session.model
        terminalAppPid = session.terminalAppPid
        agentProcessPid = session.agentProcessPid
        jumpTarget = session.jumpTarget
        transcriptPath = session.transcriptPath
        lastAction = session.lastAction
        tokens = session.tokens
        activeSeconds = session.activeSeconds
        task = session.task
    }

    public func asSession(now: Date = Date()) -> AgentSession {
        var session = AgentSession(
            id: id,
            agent: agent,
            cwd: cwd,
            hookPid: nil,
            status: Self.decodeStatus(status),
            pending: nil, // never restore a blocked permission across process death
            lastEventAt: lastEventAt,
            title: title,
            model: model,
            terminalAppPid: terminalAppPid,
            transcriptPath: transcriptPath,
            lastAction: lastAction
        )
        session.agentProcessPid = agentProcessPid
        session.jumpTarget = jumpTarget
        session.tokens = tokens
        session.activeSeconds = activeSeconds
        session.task = task
        // Restored sessions are at best idle until a live hook re-attaches.
        if session.status == .waitingPermission || session.status == .running {
            session.status = .idle
        }
        // Touch so prune doesn't instantly drop very old snapshots that
        // still have live PIDs (caller reconciles).
        _ = now
        return session
    }

    private static func encodeStatus(_ status: AgentSession.Status) -> String {
        switch status {
        case .running: "running"
        case .waitingPermission: "waitingPermission"
        case .waitingInput: "waitingInput"
        case .idle: "idle"
        }
    }

    private static func decodeStatus(_ raw: String) -> AgentSession.Status {
        switch raw {
        case "running": .running
        case "waitingPermission": .waitingPermission
        case "waitingInput": .waitingInput
        default: .idle
        }
    }
}

public struct SessionSnapshotFile: Codable, Equatable, Sendable {
    public var version: Int
    public var savedAt: Date
    public var sessions: [PersistedSession]

    public static let currentVersion = 1

    public init(version: Int = currentVersion, savedAt: Date = Date(), sessions: [PersistedSession]) {
        self.version = version
        self.savedAt = savedAt
        self.sessions = sessions
    }
}

public enum SessionPersistence {
    public static func defaultURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/rocky/sessions.json")
    }

    /// Max age of a persisted session to restore (aligned with orphanTimeout).
    public static let maxAge: TimeInterval = 2 * 60 * 60

    public static func encode(_ sessions: [AgentSession], at date: Date = Date()) throws -> Data {
        let file = SessionSnapshotFile(
            savedAt: date,
            sessions: sessions.map(PersistedSession.init(from:))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> [AgentSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(SessionSnapshotFile.self, from: data)
        guard file.version <= SessionSnapshotFile.currentVersion else { return [] }
        return file.sessions
            .filter { now.timeIntervalSince($0.lastEventAt) < maxAge }
            .map { $0.asSession(now: now) }
    }

    public static func save(
        _ sessions: [AgentSession],
        to url: URL = defaultURL(),
        fileManager: FileManager = .default
    ) throws {
        let data = try encode(sessions)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    public static func load(
        from url: URL = defaultURL(),
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [AgentSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data, now: now)) ?? []
    }
}

