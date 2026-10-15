import Testing
@testable import NineBarCore

@Suite("Radar settings storage")
struct RadarSettingsStoreTests {
    @Test("missing settings use the approved defaults")
    func missingSettingsUseApprovedDefaults() throws {
        let store = RadarSettingsStore(fileURL: try temporarySettingsURL())

        #expect(try store.load() == RadarSettings())
    }

    @Test("round trip preserves periods, alert preferences and language")
    func roundTripPreservesPeriodsAndAlerts() throws {
        let store = RadarSettingsStore(fileURL: try temporarySettingsURL())
        let value = RadarSettings(
            enabledTimeframes: [.fiveMinutes],
            notifyAtEight: false,
            notifyAtNine: true,
            soundAtNine: false,
            startAtLogin: false,
            language: .english
        )

        try store.save(value)

        #expect(try store.load() == value)
    }

    @Test("schema one settings are rewritten as the current schema and keep the user's choices")
    func schemaOneSettingsAreRewrittenAsCurrentSchema() throws {
        let url = try temporarySettingsURL()
        // Schema one files may still carry keys from removed features; they are ignored.
        let legacy = """
        {"schemaVersion":1,"settings":{"enabledTimeframes":[5],"removedOption":true,\
        "notifyAtEight":false,"notifyAtNine":true,"soundAtNine":false,"startAtLogin":false}}
        """
        try writeTestText(legacy, to: url)
        let store = RadarSettingsStore(fileURL: url)

        let migrated = try store.load()
        let persisted = try readSettingsDocument(at: url)

        #expect(migrated == RadarSettings(
            enabledTimeframes: [.fiveMinutes],
            notifyAtEight: false,
            notifyAtNine: true,
            soundAtNine: false,
            startAtLogin: false
        ))
        #expect(persisted.schemaVersion == SettingsDocument.currentSchemaVersion)
        #expect(persisted.settings == migrated)
    }

    @Test("settings saved before the language option load with the system language")
    func settingsWithoutLanguageUseSystemLanguage() throws {
        let url = try temporarySettingsURL()
        let original = """
        {"schemaVersion":2,"settings":{"enabledTimeframes":[1,5],\
        "notifyAtEight":true,"notifyAtNine":true,"soundAtNine":true,"startAtLogin":true}}
        """
        try writeTestText(original, to: url)
        let store = RadarSettingsStore(fileURL: url)

        #expect(try store.load() == RadarSettings())
        #expect(try store.load().language == .system)
    }

    @Test("future schema is rejected without changing the user file")
    func futureSchemaIsRejectedWithoutChangingTheUserFile() throws {
        let url = try temporarySettingsURL()
        let original = "{\"schemaVersion\":3,\"settings\":{}}"
        try writeTestText(original, to: url)
        let store = RadarSettingsStore(fileURL: url)

        #expect(throws: SettingsError.unsupportedVersion(3)) {
            try store.load()
        }

        #expect(try readTestText(at: url) == original)
    }

    @Test("malformed JSON throws a typed error and remains intact")
    func malformedJSONThrowsTypedErrorAndRemainsIntact() throws {
        let url = try temporarySettingsURL()
        let original = "not-json"
        try writeTestText(original, to: url)
        let store = RadarSettingsStore(fileURL: url)

        #expect(throws: SettingsError.malformedDocument) {
            try store.load()
        }

        #expect(try readTestText(at: url) == original)
    }
}
