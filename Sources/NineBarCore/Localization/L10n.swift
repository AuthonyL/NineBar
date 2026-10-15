import Foundation
import os

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
}

/// User-facing text is written as Chinese/English pairs at the call site, so every string is
/// translated by construction and the language can change while the app is running.
public enum L10n {
    private static let usesEnglish = OSAllocatedUnfairLock(
        initialState: resolvesToEnglish(.system, preferredLanguages: Locale.preferredLanguages)
    )

    public static func t(_ chinese: String, _ english: String) -> String {
        isEnglish ? english : chinese
    }

    public static var isEnglish: Bool {
        scopedEnglish ?? usesEnglish.withLock { $0 }
    }

    /// Overrides the language for the current task and the tasks it starts, without touching the
    /// app-wide choice. Tests use it so English and Chinese assertions can run in parallel.
    @TaskLocal public static var scopedEnglish: Bool?

    public static func apply(
        _ language: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        let english = resolvesToEnglish(language, preferredLanguages: preferredLanguages)
        usesEnglish.withLock { $0 = english }
    }

    static func resolvesToEnglish(_ language: AppLanguage, preferredLanguages: [String]) -> Bool {
        switch language {
        case .simplifiedChinese:
            false
        case .english:
            true
        case .system:
            !(preferredLanguages.first?.hasPrefix("zh") ?? false)
        }
    }
}
