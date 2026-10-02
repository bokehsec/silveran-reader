import Foundation

/// One thing iCloud annotation sync did on this device, shown on the diagnostics screen.
public struct SyncActivityEvent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Started, stopped, account or zone changes.
        case lifecycle
        /// Annotations saved to or deleted from iCloud.
        case sent
        /// Annotations fetched from iCloud and applied (or kept) here.
        case received
        /// A failure: iCloud refused something or couldn't be reached.
        case problem
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var summary: String
    public var detail: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        kind: Kind,
        summary: String,
        detail: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

/// When sync last reached iCloud, kept apart from the event list so routine checks that find
/// nothing new update a time instead of filling the history.
public struct SyncActivityStatus: Codable, Hashable, Sendable {
    public var lastCheckedAt: Date?
    public var lastSentAt: Date?
    public var lastReceivedAt: Date?
    public var lastProblemAt: Date?
    public var lastProblem: String?

    public init() {}
}

/// A short, persisted history of annotation sync on this device (diagnostics only). Clearing
/// or losing it never affects annotations or what is sent; a damaged file starts a new history.
public actor SyncActivityLog {
    public static let defaultLimit = 300

    private struct Stored: Codable {
        var status = SyncActivityStatus()
        var events: [SyncActivityEvent] = []
    }

    private let url: URL
    private let limit: Int
    private let now: @Sendable () -> Date
    private var stored: Stored?

    public init(
        url: URL,
        limit: Int = SyncActivityLog.defaultLimit,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.url = url
        self.limit = limit
        self.now = now
    }

    public func record(_ kind: SyncActivityEvent.Kind, _ summary: String, detail: String? = nil) {
        var value = load()
        let date = now()
        value.events.append(
            SyncActivityEvent(date: date, kind: kind, summary: summary, detail: detail)
        )
        if value.events.count > limit { value.events.removeFirst(value.events.count - limit) }
        switch kind {
            case .sent: value.status.lastSentAt = date
            case .received: value.status.lastReceivedAt = date
            case .problem:
                value.status.lastProblemAt = date
                value.status.lastProblem = summary
            case .lifecycle: break
        }
        save(value)
    }

    /// A fetch from iCloud finished, whether or not it found anything.
    public func markChecked() {
        var value = load()
        value.status.lastCheckedAt = now()
        save(value)
    }

    public func status() -> SyncActivityStatus { load().status }

    /// Newest first.
    public func events() -> [SyncActivityEvent] { load().events.reversed() }

    public func clear() { save(Stored()) }

    private func load() -> Stored {
        if let stored { return stored }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value =
            (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Stored.self, from: $0) }
            ?? Stored()
        stored = value
        return value
    }

    private func save(_ value: Stored) {
        stored = value
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
