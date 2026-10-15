import Darwin
import Foundation
import NineBarCore

let report = await HealthCheckRunner.live().run()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
FileHandle.standardOutput.write(try! encoder.encode(report))
FileHandle.standardOutput.write(Data("\n".utf8))
exit(report.ok ? 0 : 1)
