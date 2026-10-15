// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Swift Testing lives outside the default framework search paths. The test targets are
// executables (see scripts/test.sh), so point them at the active developer directory's copy:
// Command Line Tools keep it under Library/, Xcode under the macOS platform.
let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? "/Library/Developer/CommandLineTools"
let testingFrameworkPath = [
    developerDirectory + "/Library/Developer/Frameworks",
    developerDirectory + "/Platforms/MacOSX.platform/Developer/Library/Frameworks"
].first { FileManager.default.fileExists(atPath: $0 + "/Testing.framework") }
let testingSwiftSettings: [SwiftSetting] = testingFrameworkPath.map { path in
    [.unsafeFlags(["-F", path])]
} ?? []
let testingLinkerSettings: [LinkerSetting] = testingFrameworkPath.map { path in
    [.unsafeFlags(["-F", path, "-framework", "Testing", "-Xlinker", "-rpath", "-Xlinker", path])]
} ?? []

let package = Package(
    name: "NineBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NineBarCore", targets: ["NineBarCore"]),
        .library(name: "NineBarUI", targets: ["NineBarUI"]),
        .executable(name: "NineBar", targets: ["NineBar"]),
        .executable(name: "NineBarHealthCheck", targets: ["NineBarHealthCheck"])
    ],
    targets: [
        .target(name: "NineBarCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "NineBarUI", dependencies: ["NineBarCore"]),
        .executableTarget(name: "NineBar", dependencies: ["NineBarCore", "NineBarUI"]),
        .executableTarget(name: "NineBarHealthCheck", dependencies: ["NineBarCore"]),
        .executableTarget(name: "NineBarCoreTests", dependencies: ["NineBarCore"], path: "Tests/NineBarCoreTests", resources: [.copy("Fixtures")], swiftSettings: testingSwiftSettings, linkerSettings: testingLinkerSettings),
        .executableTarget(name: "NineBarUITests", dependencies: ["NineBarUI", "NineBarCore"], path: "Tests/NineBarUITests", swiftSettings: testingSwiftSettings, linkerSettings: testingLinkerSettings)
    ]
)
