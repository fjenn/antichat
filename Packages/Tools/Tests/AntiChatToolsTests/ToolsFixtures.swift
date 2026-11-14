// M6.T07 test support: fixture lookup ($ANTICHAT_FIXTURES, else the fixtures submodule next to the package).
import Foundation

enum ToolsFixtures {
    static let root: URL = {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures", isDirectory: true)
    }()

    static func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }
}
