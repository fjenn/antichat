// M6.T01/T02: where an attachment's extracted Markdown lives. On disk next to the media store
// (`<Media>/<yyyy>/<sha>.<ext>` → `<Media>/extracted/<sha>.md`); incognito Markdown only in this process's memory
// (R-090), dropped with the session (`forget`). The prompt layer reads it through here.
import AntiChatStorage
import Foundation

public final class ExtractedTextStore: @unchecked Sendable {
    public static let shared = ExtractedTextStore()
    private let lock = NSLock()
    private var mem: [String: String] = [:]

    public func memory(_ sha: String) -> String? { lock.withLock { mem[sha] } }
    public func putMemory(_ sha: String, _ md: String) { lock.withLock { mem[sha] = md } }
    public func forget(_ shas: [String]) { lock.withLock { for s in shas { mem.removeValue(forKey: s) } } }

    /// The Markdown of a blob intake read (memory first, then `<Media>/extracted/<sha>.md`).
    public func markdown(for blob: FileBlobRecord) -> String? {
        if let m = memory(blob.sha256) { return m }
        let media = URL(fileURLWithPath: blob.path).deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: media.appendingPathComponent("extracted/\(blob.sha256).md"), encoding: .utf8)
    }
}
