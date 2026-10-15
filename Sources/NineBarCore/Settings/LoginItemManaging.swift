import Foundation

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

public enum LoginItemError: Error, Equatable, Sendable {
    case unavailable
}

public protocol LoginItemManaging: Sendable {
    func status() async -> LoginItemStatus
    func setEnabled(_ enabled: Bool) async throws
}

public protocol LoginItemsSettingsOpening: Sendable {
    func openLoginItemsSettings() async -> Bool
}
