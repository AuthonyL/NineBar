import Testing
@testable import NineBarCore

@Test("stable application identity")
func stableApplicationIdentity() {
    #expect(AppMetadata.bundleIdentifier == "io.github.authonyl.NineBar")
    #expect(AppMetadata.displayName == "九转雷达")
    #expect(AppMetadata.minimumMacOSMajorVersion == 14)
}
