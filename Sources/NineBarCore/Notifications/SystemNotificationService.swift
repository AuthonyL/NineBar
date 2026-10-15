import Foundation
@preconcurrency import UserNotifications

enum SystemNotificationSound: Equatable, Sendable {
    case `default`
}

struct SystemNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let sound: SystemNotificationSound?
}

protocol NotificationCenterAdapting: Sendable {
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func add(_ request: SystemNotificationRequest) async throws
}

extension NotificationCenterAdapting {
    func authorizationStatus() async -> NotificationAuthorizationStatus {
        .unknown
    }
}

actor SystemNotificationCenterAdapter: NotificationCenterAdapting {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }

    func add(_ request: SystemNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        if request.sound == .default {
            content.sound = .default
        }
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }
}

public actor SystemNotificationService: NotificationSending, NotificationAuthorizationStatusProviding {
    private let notificationCenter: any NotificationCenterAdapting
    private var authorization: Bool?

    public init() {
        self.notificationCenter = SystemNotificationCenterAdapter()
    }

    init(notificationCenter: any NotificationCenterAdapting) {
        self.notificationCenter = notificationCenter
    }

    public func requestAuthorization() async throws -> Bool {
        if let authorization {
            return authorization
        }

        let granted = try await notificationCenter.requestAuthorization()
        authorization = granted
        return granted
    }

    public func send(_ event: NotificationEvent, instrumentName: String) async throws {
        guard try await requestAuthorization() else {
            return
        }
        try await notificationCenter.add(notificationRequest(for: event, instrumentName: instrumentName))
    }

    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        if let authorization {
            return authorization ? .granted : .denied
        }
        return await notificationCenter.authorizationStatus()
    }

    private func notificationRequest(for event: NotificationEvent, instrumentName: String) -> SystemNotificationRequest {
        let title: String
        switch event.level {
        case .level8:
            title = L10n.t("接近九转完成", "Nine-count almost complete")
        case .level9:
            title = L10n.t("九转已确认", "Nine-count confirmed")
        }
        return SystemNotificationRequest(
            identifier: event.key,
            title: title,
            body: notificationBody(for: event, instrumentName: instrumentName),
            sound: event.playsSound ? .default : nil
        )
    }

    private func notificationBody(for event: NotificationEvent, instrumentName: String) -> String {
        let sequence = event.sequence
        let timeframe = L10n.t("\(sequence.timeframe.rawValue)分钟", "\(sequence.timeframe.rawValue) min")
        let direction = sequence.direction == .top
            ? L10n.t("顶部序列", "top sequence")
            : L10n.t("底部序列", "bottom sequence")
        let extremeLabel = sequence.direction == .top
            ? L10n.t("区间高点", "range high")
            : L10n.t("区间低点", "range low")
        let price = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), sequence.extremePrice)
        return "\(instrumentName) · \(timeframe) · \(direction) · \(extremeLabel) \(price)"
    }
}
