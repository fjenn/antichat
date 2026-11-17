// ⌘K chats (M1.T11 step 3, R-012 AC1): FTS5 over titles ∪ message bodies (bm25, snippet highlights) through
// `ChatListService.search`, run off the main actor so typing never waits on the database (NFR-U10). An empty
// query lists the recent chats (step 5).
import AntiChatDesign
import AntiChatHarness
import Foundation

enum ChatsProvider {
    /// Rows shown for a query (title + body matches) and for an empty query (recents).
    static let searchLimit = 30
    static let recentLimit = 20

    /// Searches on a background task; `nil` when cancelled (a newer query superseded it).
    static func chats(_ query: String, service: ChatListService) async -> [ChatSearchHit]? {
        let task = Task.detached(priority: .userInitiated) { () -> [ChatSearchHit] in
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                return q.isEmpty
                    ? try service.recentChats(limit: recentLimit)
                    : try service.search(q, limit: searchLimit)
            } catch {
                return []
            }
        }
        let hits = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled ? nil : hits
    }

    @MainActor
    static func items(_ hits: [ChatSearchHit]) -> [PaletteItem] {
        hits.map { hit in
            let title = hit.title.isEmpty ? CopyKey("side.untitled").string() : hit.title
            let excerpt = plain(hit.excerpt)
            return PaletteItem(id: "chat.\(hit.chatID)", kind: .chat(hit.chatID, messageID: hit.messageID),
                               title: title, subtitle: excerpt.isEmpty ? nil : excerpt.map(\.text).joined(),
                               excerpt: excerpt, symbol: hit.isEvil ? "flame" : "bubble.left",
                               titleMatched: hit.titleMatched)
        }
    }

    /// A snippet as plain text: Markdown marks (`**`, `#`, backticks, table pipes and rules, list bullets) are dropped
    /// and runs of white space collapse; the matched runs stay marked.
    static func plain(_ runs: [ChatSearchHit.Run]) -> [ChatSearchHit.Run] {
        var out: [ChatSearchHit.Run] = []
        for run in runs {
            var t = run.text
            t = t.replacingOccurrences(of: #":?-{3,}:?"#, with: " ", options: .regularExpression)  // table rules
            t = t.replacingOccurrences(of: #"[*_`~|>]+|#{1,6}\s|\[|\]\([^)]*\)?|\]"#, with: " ", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if t.isEmpty { continue }
            if let last = out.last, last.isMatch == run.isMatch {
                out[out.count - 1].text = (last.text + t).replacingOccurrences(of: "  ", with: " ")
            } else {
                if let last = out.last, last.text.hasSuffix(" "), t.hasPrefix(" ") { t.removeFirst() }
                if !t.isEmpty { out.append(ChatSearchHit.Run(text: t, isMatch: run.isMatch)) }
            }
        }
        if let first = out.first, !first.isMatch { out[0].text = String(first.text.drop(while: { $0 == " " })) }
        if let last = out.last, !last.isMatch, last.text.hasSuffix(" ") { out[out.count - 1].text.removeLast() }
        return out.filter { !$0.text.isEmpty }
    }
}
