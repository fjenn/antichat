// M6.T09/T10: the summary every file-out tool answers with (line 1, JSON) + one sentence for the model. The FileCard and
// the ActivityLine read the JSON back from the persisted activity: file name, path, size, version and — for version 2
// and later — the whole chain (the ‹ v1 v2 › switcher). The model gets the artifact_id for later `revises` calls.
// M9 review T1: a card is read from trusted, host-written text only. A file-out tool's card is its first line; a
// `run_python` result's cards are the `files` of its first line (the host's summary), never later lines, which carry the
// jailed code's raw stdout, and only cards whose path lies inside the run's `output_dir`.
import Foundation

public struct FileOutResult: Codable, Sendable, Equatable {
    public var artifact_id: String
    public var file: String
    public var format: String
    public var pages: Int?
    public var path: String
    public var size: Int64
    public var version: Int
    public var versions: [VersionInfo]?

    public static func card(_ s: SavedArtifact, format: String, pages: Int?, versions: [VersionInfo] = []) -> FileOutResult {
        FileOutResult(artifact_id: s.artifactID, file: s.filename, format: format, pages: pages, path: s.path,
                      size: s.size, version: s.version, versions: versions.isEmpty ? nil : versions)
    }

    public static func text(_ s: SavedArtifact, format: String, pages: Int?, versions: [VersionInfo] = []) -> String {
        let r = card(s, format: format, pages: pages, versions: versions)
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? e.encode(r)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let v = s.version > 1 ? " (version \(s.version))" : ""
        // A file name from the jail may hold a line break: never let it start a line of its own.
        let name = String(s.filename.map { $0.isNewline ? " " : $0 })
        return json + "\nCreated \(name)\(v). It is already shown to the user. Reply with one short sentence; do not describe how it is shown, mention buttons or a card, or repeat its contents. To change it later, call the tool again with revises: \"\(s.artifactID)\"."
    }

    public static func parse(_ text: String) -> FileOutResult? { parseAll(text).first }

    public static func parseAll(_ text: String) -> [FileOutResult] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return [] }
        if let card = decode(first) { return [card] }
        guard let summary = try? JSONDecoder().decode(RunPythonSummary.self, from: Data(first.utf8)) else { return [] }
        if let files = summary.files {
            guard let dir = summary.outputDir else { return [] }
            return files.filter { isInside($0.path, folder: dir) }
        }
        // A run_python result saved before the fix (no `files`): card lines after the summary, except any line the
        // jailed code printed (its stdout / stderr / error are in the summary).
        let untrusted = [summary.stdout, summary.stderr, summary.error?.message ?? "", summary.error?.traceback ?? ""]
        return lines.dropFirst().compactMap { line in
            guard let card = decode(line) else { return nil }
            let raw = line.trimmingCharacters(in: .whitespaces)
            return untrusted.contains { $0.contains(raw) } ? nil : card  // M9 review T1: a forged card
        }
    }

    static func decode(_ line: Substring) -> FileOutResult? {
        try? JSONDecoder().decode(FileOutResult.self, from: Data(line.utf8))
    }

    /// Whether `path` lies strictly inside `folder` (`..` removed; compared as written and with symlinks resolved, so a
    /// file deleted since, or a /var ↔ /private/var spelling, still compares).
    public static func isInside(_ path: String, folder: String) -> Bool {
        guard path.hasPrefix("/"), folder.hasPrefix("/") else { return false }
        func under(_ p: URL, _ f: URL) -> Bool {
            let pc = p.pathComponents, fc = f.pathComponents
            return pc.count > fc.count && Array(pc.prefix(fc.count)) == fc
        }
        let p = URL(fileURLWithPath: path).standardizedFileURL, f = URL(fileURLWithPath: folder).standardizedFileURL
        return under(p, f) || under(p.resolvingSymlinksInPath(), f.resolvingSymlinksInPath())
    }
}
