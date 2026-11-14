// M6.T02 (R-270 AC1): `CountTokens` — counts with the model's own tokenizer without loading weights. MLX models carry
// `tokenizer.json` in their folder (swift-transformers `AutoTokenizer.from(modelFolder:)`, the loader MLXAdapter uses);
// a GGUF file uses a `tokenizer.json` next to it when one exists. No tokenizer → ⌈characters / 4⌉, flagged estimated.
// Tokenizers are cached per folder (one load per model per helper life).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Tokenizers

public actor TokenCounter {
    private var cache: [String: any Tokenizers.Tokenizer] = [:]
    private var missing: Set<String> = []

    public init() {}

    public func reply(_ r: CountTokensRequest) async -> SearchReply {
        var texts = r.texts
        if let url = r.fileURL {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else {
                return SearchReply(error: AntiChatError.engine("countTokensFailed", "unreadable \(url.lastPathComponent)"))
            }
            texts = [s]
        }
        guard let tok = await tokenizer(for: r.modelSlot) else {
            return SearchReply(tokens: texts.map(CountTokensRequest.estimate), tokensEstimated: true)
        }
        return SearchReply(tokens: texts.map { tok.encode(text: $0, addSpecialTokens: false).count }, tokensEstimated: false)
    }

    /// The folder holding `tokenizer.json` for a slot: the model folder (MLX) or the GGUF file's folder.
    static func tokenizerFolder(_ slot: ModelSlot) -> URL? {
        var dir = URL(fileURLWithPath: slot.path)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) { return nil }
        if !isDir.boolValue { dir.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path) ? dir : nil
    }

    func tokenizer(for slot: ModelSlot) async -> (any Tokenizers.Tokenizer)? {
        guard let dir = Self.tokenizerFolder(slot) else { return nil }
        if let t = cache[dir.path] { return t }
        if missing.contains(dir.path) { return nil }
        do {
            let t = try await AutoTokenizer.from(modelFolder: dir)
            cache[dir.path] = t
            return t
        } catch {
            AppLog.log(.engine, .notice, "tokenizer load failed for \(slot.key): \(error)")
            missing.insert(dir.path)
            return nil
        }
    }
}
