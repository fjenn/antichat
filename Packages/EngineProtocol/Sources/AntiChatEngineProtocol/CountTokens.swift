// M6.T02 (R-270 AC1): token counts by the model's own tokenizer. `CountTokensRequest{modelSlot, texts | fileURL}` →
// `SearchReply.tokens` (one count per text, or one for the file's UTF-8 text), answered without loading weights (the
// helper owns the tokenizers; `tokenizer.json` next to the model). `estimated` = no tokenizer was found, counts are
// ⌈characters / 4⌉. Protocol version 5.
import Foundation

public struct CountTokensRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var modelSlot: ModelSlot
    public var texts: [String]
    /// A UTF-8 text file (the extracted Markdown of a large document) instead of `texts`.
    public var fileURL: URL?
    public init(requestID: UUID = UUID(), modelSlot: ModelSlot, texts: [String] = [], fileURL: URL? = nil) {
        self.requestID = requestID
        self.modelSlot = modelSlot
        self.texts = texts
        self.fileURL = fileURL
    }

    /// The fallback count (≈ 4 characters per token for Latin text).
    public static func estimate(_ text: String) -> Int { (text.count + 3) / 4 }
}
