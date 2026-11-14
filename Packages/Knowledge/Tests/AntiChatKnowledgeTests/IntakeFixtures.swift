// M6.T01 test support: fixture lookup ($ANTICHAT_FIXTURES, else the fixtures submodule next to the package).
import Foundation

enum IntakeFixtures {
    static let root: URL = {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures", isDirectory: true)
    }()

    static func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    /// A scratch directory removed by the caller.
    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
