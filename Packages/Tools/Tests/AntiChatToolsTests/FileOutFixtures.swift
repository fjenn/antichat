// M6.T09 test support: the file-out golden specs (fixtures/docs/golden-out/specs, make-fileout-golden.py), their image
// refs (CC0 photos) and the frozen expected outputs (golden-out/expected). `ANTICHAT_GOLDEN_WRITE=1` writes the
// expected files instead of comparing (once, then reviewed and frozen).
import Foundation
@testable import AntiChatTools

enum FileOutFixtures {
    static var specsDir: URL { ToolsFixtures.url("docs/golden-out/specs") }
    static var expectedDir: URL { ToolsFixtures.url("docs/golden-out/expected") }
    static var available: Bool { FileManager.default.fileExists(atPath: specsDir.appendingPathComponent("pdf-01.json").path) }
    static var writeGolden: Bool { ProcessInfo.processInfo.environment["ANTICHAT_GOLDEN_WRITE"] == "1" }

    static func ids(_ format: String) -> [String] {
        (1...30).map { String(format: "\(format)-%02d", $0) }
    }

    static func specJSON(_ id: String) throws -> String {
        try String(contentsOf: specsDir.appendingPathComponent("\(id).json"), encoding: .utf8)
    }

    static func spec(_ id: String) throws -> CreateDocumentSpec {
        try CreateDocumentTool.decode(specJSON(id))
    }

    static let images: [String: FileOutImage] = {
        guard let data = try? Data(contentsOf: specsDir.appendingPathComponent("images.json")),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var out: [String: FileOutImage] = [:]
        for (ref, rel) in map {
            if let d = try? Data(contentsOf: ToolsFixtures.url(rel)) { out[ref] = FileOutImage(data: d) }
        }
        return out
    }()

    /// Compares `actual` with `expected/<name>` (or writes it under ANTICHAT_GOLDEN_WRITE=1). Returns nil when equal.
    static func golden(_ name: String, _ actual: Data) throws -> String? {
        let url = expectedDir.appendingPathComponent(name)
        if writeGolden {
            try FileManager.default.createDirectory(at: expectedDir, withIntermediateDirectories: true)
            try actual.write(to: url)
            return nil
        }
        guard let want = try? Data(contentsOf: url) else { return "missing golden \(name)" }
        return want == actual ? nil : "golden \(name) differs"
    }

    /// `ANTICHAT_FILEOUT_DUMP=<dir>`: keep every rendered file for review (open checks, eyeballing).
    static func dump(_ name: String, _ data: Data) {
        guard let dir = ProcessInfo.processInfo.environment["ANTICHAT_FILEOUT_DUMP"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent(name))
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `unzip -p` one part of an OOXML file.
    static func part(_ file: URL, _ name: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", file.path, name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func entries(_ file: URL) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        p.arguments = ["-1", file.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
