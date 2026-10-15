import Testing
@testable import NineBarCore

@Suite("Rotating diagnostic logger")
struct RotatingLoggerTests {
    @Test("rotation keeps complete safe JSON lines within the configured file limit")
    func rotationKeepsCompleteSafeJSONLines() async throws {
        let directory = try temporaryLogDirectory()
        let logger = RotatingLogger(
            directoryURL: directory,
            maximumFileBytes: 1_024,
            maximumFileCount: 2
        )

        for offset in 0..<32 {
            try await logger.log(
                timestamp: testDate(seconds: offset),
                component: .marketData,
                errorCategory: .unavailable,
                instrument: sh("600519")
            )
        }

        let files = try testLogFiles(in: directory)
        #expect(files.count == 2)

        for file in files {
            let lines = try testLogLines(in: file)
            #expect(!lines.isEmpty)
            for line in lines {
                #expect(try testLogLineKeys(line).isSubset(of: ["timestamp", "component", "errorCategory", "instrumentID"]))
                #expect(try testLogLineKeys(line).isSuperset(of: ["timestamp", "component", "errorCategory"]))
                #expect(try testLogLineInstrumentID(line) == "sh.600519")
            }
        }
    }

    @Test("recent categories are returned newest first with no more than five entries")
    func recentCategoriesAreSafeAndBounded() async throws {
        let logger = RotatingLogger(directoryURL: try temporaryLogDirectory())
        let categories: [DiagnosticErrorCategory] = [
            .unavailable, .malformedData, .storage, .permission, .network, .configuration
        ]

        for (offset, category) in categories.enumerated() {
            try await logger.log(
                timestamp: testDate(seconds: offset),
                component: .coordinator,
                errorCategory: category
            )
        }

        #expect(await logger.recentErrorCategories() == [
            .configuration, .network, .permission, .storage, .malformedData
        ])
    }
}
