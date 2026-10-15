import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("menu bar icon verification failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("expected source, packaged, and application icon paths")
}

let sourcePath = CommandLine.arguments[1]
let packagedPath = CommandLine.arguments[2]
let applicationIconPath = CommandLine.arguments[3]
let fileManager = FileManager.default

guard fileManager.contentsEqual(atPath: sourcePath, andPath: packagedPath) else {
    fail("packaged MenuBarIcon.png does not match the project asset")
}
guard !fileManager.contentsEqual(atPath: packagedPath, andPath: applicationIconPath) else {
    fail("menu bar icon must remain separate from the application icon")
}
guard
    let data = try? Data(contentsOf: URL(fileURLWithPath: packagedPath)),
    let representation = NSBitmapImageRep(data: data)
else {
    fail("packaged MenuBarIcon.png is not a readable bitmap")
}
guard representation.hasAlpha else {
    fail("packaged MenuBarIcon.png has no alpha channel")
}
guard representation.pixelsWide <= 144, representation.pixelsHigh <= 144 else {
    fail("packaged MenuBarIcon.png exceeds the 144-pixel Retina source limit")
}
guard representation.pixelsWide >= 36, representation.pixelsHigh >= 36 else {
    fail("packaged MenuBarIcon.png is too small for Retina rendering")
}

var visiblePixels = 0
var borderAlpha: CGFloat = 0
let width = representation.pixelsWide
let height = representation.pixelsHigh

for y in 0..<height {
    for x in 0..<width {
        let alpha = representation.colorAt(x: x, y: y)?.alphaComponent ?? 0
        if alpha > 0.01 {
            visiblePixels += 1
        }
        if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
            borderAlpha = max(borderAlpha, alpha)
        }
    }
}

guard borderAlpha <= 0.01 else {
    fail("foreground cutout must have a fully transparent outer border")
}

let visibleCoverage = Double(visiblePixels) / Double(width * height)
guard (0.2...0.55).contains(visibleCoverage) else {
    fail("foreground alpha coverage is outside the expected cutout range")
}

let centerAlpha = representation.colorAt(x: width / 2, y: height / 2)?.alphaComponent ?? 0
guard centerAlpha > 0.9 else {
    fail("foreground subject is not visible at the image center")
}

print("menu bar icon verified: \(width)x\(height), visible coverage \(visibleCoverage)")
