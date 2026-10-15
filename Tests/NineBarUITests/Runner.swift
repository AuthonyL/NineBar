import Testing
import Darwin
import NineBarCore

@main
struct NineBarUITestsRunner {
    static func main() async {
        // Assertions are written against the Chinese text, whatever the machine language is.
        L10n.apply(.simplifiedChinese)
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
