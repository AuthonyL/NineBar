import Foundation

public enum NotificationLevel: Int, Codable, Sendable {
    case level8 = 8
    case level9 = 9
}

public struct NotificationEvent: Equatable, Sendable {
    public let level: NotificationLevel
    public let sequence: SequenceSnapshot
    public let playsSound: Bool

    public init(
        level: NotificationLevel,
        sequence: SequenceSnapshot,
        playsSound: Bool? = nil
    ) {
        self.level = level
        self.sequence = sequence
        self.playsSound = playsSound ?? (level == .level9)
    }

    public var key: String {
        "\(sequence.id)|\(level.rawValue)"
    }
}

public protocol NotificationSending: Sendable {
    func requestAuthorization() async throws -> Bool
    func send(_ event: NotificationEvent, instrumentName: String) async throws
}

public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case unknown
    case granted
    case denied
}

public protocol NotificationAuthorizationStatusProviding: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
}

public struct NotificationPolicy: Sendable {
    public init() {}

    public func events(previous: SequenceSnapshot?, current: SequenceSnapshot) -> [NotificationEvent] {
        let sameSequence = previous?.id == current.id
        let crossedLevel8 = current.count >= NotificationLevel.level8.rawValue
            && (!sameSequence || (previous?.count ?? 0) < NotificationLevel.level8.rawValue)
        let reachedConfirmedLevel9 = current.count == NotificationLevel.level9.rawValue
            && current.phase == .confirmed
            && (!sameSequence || previous?.count != NotificationLevel.level9.rawValue || previous?.phase != .confirmed)

        var events: [NotificationEvent] = []
        if crossedLevel8 {
            events.append(NotificationEvent(level: .level8, sequence: current))
        }
        if reachedConfirmedLevel9 {
            events.append(NotificationEvent(level: .level9, sequence: current))
        }
        return events
    }
}
