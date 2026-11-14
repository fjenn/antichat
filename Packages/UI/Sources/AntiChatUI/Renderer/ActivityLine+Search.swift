// M7.T03 step 5 / 9 (R-254, R-080 AC4): the web steps on the ActivityLine. Running → `status.searching` (live, shown at
// send when the Web search chip is on) · done → `act.searched` ("Searched the web · {count} sources"; `read_url`:
// `act.read` "Read {site}"), expanding to the queries and the source rows · failed with every engine down →
// `search.failed` + [Retry search] (the answer continues without the web, fail-open). The data comes from the
// persisted activity (arguments + the `<web_results>` block's source lines), so a reloaded chat shows the same step.
import AntiChatDesign
import AntiChatHarness
import Foundation
import SwiftUI

enum SearchActivity {
    static func isSearch(_ a: ToolActivity) -> Bool { a.kind == .tool && WebSearchTools.names.contains(a.tool) }

    struct SourceLine: Equatable { var n: Int; var title: String; var site: String; var url: String }

    static func queries(_ a: ToolActivity) -> [String] {
        struct Q: Decodable { var queries: [String]?; var url: String? }
        guard let q = try? JSONDecoder().decode(Q.self, from: Data(a.argumentsJSON.utf8)) else { return [] }
        return q.queries ?? q.url.map { [$0] } ?? []
    }

    static let sourceLine = try! NSRegularExpression(pattern: #"^\[(\d+)\] (.*) — (.*) — (\S+)"#, options: [.anchorsMatchLines])

    /// The numbered `Sources:` lines of the step's `<web_results>` block (fetched sources only).
    static func sources(_ a: ToolActivity) -> [SourceLine] {
        guard let r = a.result, r.hasPrefix("<web_results") else { return [] }
        let ns = r as NSString
        return sourceLine.matches(in: r, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let n = Int(ns.substring(with: m.range(at: 1))) else { return nil }
            return SourceLine(n: n, title: ns.substring(with: m.range(at: 2)), site: ns.substring(with: m.range(at: 3)),
                              url: ns.substring(with: m.range(at: 4)))
        }
    }

    /// R-091 AC3: the country hint the step's requests carried (`region="de"` on the `<web_results>` tag), nil = none.
    static func region(_ a: ToolActivity) -> String? {
        guard let r = a.result, r.hasPrefix("<web_results"), let line = r.split(separator: "\n").first,
              let m = line.firstMatch(of: /region="([a-z]{2})"/) else { return nil }
        return String(m.output.1).uppercased()
    }

    static func failedAllEngines(_ a: ToolActivity) -> Bool { a.state == .failed && (a.result ?? "").contains("search.failed") }

    static func label(_ a: ToolActivity) -> CopyText? {
        switch a.state {
        case .running, .awaitingApproval: return CopyText(CopyKey("status.searching"))
        case .done:
            let list = sources(a)
            if a.tool == "read_url" { return CopyText(CopyKey("act.read"), ["site": list.first.map { CitationPill.domain($0.site) } ?? ""]) }
            if let region = region(a) { return CopyText(CopyKey("act.searched.region"), ["count": "\(list.count)", "region": region]) }
            return CopyText(CopyKey("act.searched"), ["count": "\(list.count)"])
        case .failed where failedAllEngines(a): return CopyText(CopyKey("search.failed"))
        default: return nil
        }
    }
}

struct SearchActivityDetail: View {
    let activity: ToolActivity
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            ForEach(SearchActivity.queries(activity), id: \.self) { q in
                Label { Text(verbatim: q) } icon: { Image(systemName: "magnifyingglass") }
                    .typeStyle(.caption).foregroundStyle(Color.textSecondary)
            }
            ForEach(SearchActivity.sources(activity), id: \.n) { s in
                Button {
                    if let u = URL(string: s.url) { openURL(u) }
                } label: {
                    HStack(spacing: Spacing.space2) {
                        Text(verbatim: "\(s.n)").monospacedDigit().foregroundStyle(Color.textTertiary)
                        Text(verbatim: s.title).foregroundStyle(Color.textSecondary).lineLimit(1)
                        Text(verbatim: CitationPill.domain(s.site)).foregroundStyle(Color.textTertiary).lineLimit(1)
                    }
                    .typeStyle(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("activityDetail")
    }
}

/// A one-line note of the reply (`ToolActivity.Kind.notice`; M7.T03: `network.offlineForSearch`).
struct ActivityNoticeView: View {
    let activity: ToolActivity
    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "wifi.slash").foregroundStyle(Color.textSecondary)
            Text(CopyKey(activity.tool)).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("activityNotice")
        .probeID("activityNotice-\(activity.tool)")
    }
}
