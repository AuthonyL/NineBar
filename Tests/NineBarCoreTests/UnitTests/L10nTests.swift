import Testing
@testable import NineBarCore

@Suite("L10nTests")
struct L10nTests {
    @Test("the system language resolves to Chinese only for Chinese preferences")
    func systemLanguageFollowsPreferredLanguages() {
        #expect(!L10n.resolvesToEnglish(.system, preferredLanguages: ["zh-Hans-CN", "en-US"]))
        #expect(!L10n.resolvesToEnglish(.system, preferredLanguages: ["zh-Hant-TW"]))
        #expect(L10n.resolvesToEnglish(.system, preferredLanguages: ["en-US", "zh-Hans-CN"]))
        #expect(L10n.resolvesToEnglish(.system, preferredLanguages: ["ja-JP"]))
        #expect(L10n.resolvesToEnglish(.system, preferredLanguages: []))
    }

    @Test("an explicit language ignores the system preference")
    func explicitLanguageWins() {
        #expect(!L10n.resolvesToEnglish(.simplifiedChinese, preferredLanguages: ["en-US"]))
        #expect(L10n.resolvesToEnglish(.english, preferredLanguages: ["zh-Hans-CN"]))
    }

    @Test("a scoped language picks the matching text")
    func scopedLanguagePicksText() {
        L10n.$scopedEnglish.withValue(true) {
            #expect(L10n.t("九转雷达", "NineBar") == "NineBar")
            #expect(AppMetadata.displayName == "NineBar")
        }
        L10n.$scopedEnglish.withValue(false) {
            #expect(L10n.t("九转雷达", "NineBar") == "九转雷达")
        }
    }

    @Test("diagnostic categories have English text")
    func diagnosticCategoriesHaveEnglishText() {
        L10n.$scopedEnglish.withValue(true) {
            #expect(DiagnosticErrorCategory.network.displayText == "Network error")
            #expect(DiagnosticErrorCategory.unknown.displayText == "Unknown error")
        }
    }
}
