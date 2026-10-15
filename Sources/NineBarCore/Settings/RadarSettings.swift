import Foundation

public struct RadarSettings: Codable, Equatable, Sendable {
    public var enabledTimeframes: Set<Timeframe>
    public var notifyAtEight: Bool
    public var notifyAtNine: Bool
    public var soundAtNine: Bool
    public var startAtLogin: Bool
    public var language: AppLanguage

    public init(
        enabledTimeframes: Set<Timeframe> = [.oneMinute, .fiveMinutes],
        notifyAtEight: Bool = true,
        notifyAtNine: Bool = true,
        soundAtNine: Bool = true,
        startAtLogin: Bool = true,
        language: AppLanguage = .system
    ) {
        self.enabledTimeframes = enabledTimeframes
        self.notifyAtEight = notifyAtEight
        self.notifyAtNine = notifyAtNine
        self.soundAtNine = soundAtNine
        self.startAtLogin = startAtLogin
        self.language = language
    }

    private enum CodingKeys: String, CodingKey {
        case enabledTimeframes
        case notifyAtEight
        case notifyAtNine
        case soundAtNine
        case startAtLogin
        case language
    }

    /// Settings saved before the language option existed load with the system language.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledTimeframes = try container.decode(Set<Timeframe>.self, forKey: .enabledTimeframes)
        notifyAtEight = try container.decode(Bool.self, forKey: .notifyAtEight)
        notifyAtNine = try container.decode(Bool.self, forKey: .notifyAtNine)
        soundAtNine = try container.decode(Bool.self, forKey: .soundAtNine)
        startAtLogin = try container.decode(Bool.self, forKey: .startAtLogin)
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    }
}
