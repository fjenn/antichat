// M2.T06 step 1 (blueprint E §E.2.7 "Who is resident when"): what must stay loaded beside the chat model when the
// fit rule runs — the embedding model on every tier, plus the Voice set (STT + VAD/turn + TTS) when Voice is on.
// The reranker is on demand (`on_demand`), image/video models evict the LLM on T1–T2 and are checked on their own.
import Foundation

public enum ResidencyTable {
    public static func mustStayGB(cell: CatalogCell, catalog: ModelCatalog, voiceEnabled: Bool) -> Double {
        var ids: [String] = cell.embed.map { [$0] } ?? []
        if voiceEnabled { ids += cell.voice?.normal ?? [] }
        return ids.compactMap { catalog.models[$0] }.reduce(0) { $0 + FitRule.resident($1) }
    }
}
