// CitationPill + CitationHoverCard (M7.T03 step 7; R-250 AC1; components.md §3 CitationPill; S-10). In a finished
// reply `[n]` / `[n,m]` become inline pills **only** when `n` is a source of the reply with `fetched == true`
// (CitationValidator; a snippet-only result counts only if its snippet was in the evidence). Other indices are
// dropped from the text and counted in the log (no content). A pill shows the source's site ("+N" for more); hover
// shows the card (favicon from the fetched page ≤ 16 KB, title, domain); a click opens the page in the browser.
// Design references (P-files-tools-10, design only): Vane `MessageRenderer/Citation.tsx`, Open WebUI
// `Messages/Citations.svelte`.
import AntiChatDesign
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import AppKit
import MarkdownView
import SwiftUI

typealias WebSourceRecord = MessageProvenance.WebSourceRecord

extension EnvironmentValues {
    /// The reply's web sources (pills and hover cards read them).
    @Entry var webSources: [WebSourceRecord] = []
}

enum CitationPill {
    static let scheme = "antichat-cite"

    /// The reply text with valid citations as `[site](antichat-cite://n,m)` links (inline pills); invalid ones removed.
    static func linkify(_ text: String, sources: [WebSourceRecord], checking: Bool = false) -> (text: String, cited: [Int], dropped: Int) {
        guard !sources.isEmpty else { return (text, [], 0) }
        let web = sources.map {
            WebSource(n: $0.n, url: $0.url, title: $0.title, site: $0.site, date: $0.date, snippet: $0.snippet, fetched: $0.fetched)
        }
        let r = CitationValidator.validate(text, sources: web)
        if r.dropped > 0 { AppLog.log(.tools, .notice, "dropped \(r.dropped) citation(s): not a fetched source of the reply") }
        guard !r.citations.isEmpty else { return (tidy(r.text), [], r.dropped) }
        let byN = Dictionary(sources.map { ($0.n, $0) }, uniquingKeysWith: { a, _ in a })
        var out = r.text as NSString
        var cited: [Int] = []
        // Back to front so earlier locations stay valid.
        for c in r.citations.reversed() {
            let marker = "[" + c.sources.map(String.init).joined(separator: ",") + "]"
            let range = NSRange(location: c.location, length: (marker as NSString).length)
            guard range.location + range.length <= out.length, out.substring(with: range) == marker else { continue }
            let label = Self.label(c.sources.compactMap { byN[$0] })
            let pill = "[\(label)](\(scheme)://\(c.sources.map(String.init).joined(separator: ","))\(checking ? "?checking" : ""))"
            // The pill follows the sentence's punctuation ("… 27. [pill]"), as ChatGPT draws it; text never starts
            // right after an inline pill (the embedded view would wrap it to the next line).
            let after = range.location + range.length
            var punct = ""
            while after + (punct as NSString).length < out.length {
                let ch = out.substring(with: NSRange(location: after + (punct as NSString).length, length: 1))
                guard ".,;:!?".contains(ch) else { break }
                punct += ch
            }
            let replaced = NSRange(location: range.location, length: range.length + (punct as NSString).length)
            let next = replaced.location + replaced.length
            let needsSpace = next < out.length && !out.substring(with: NSRange(location: next, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            out = out.replacingCharacters(in: replaced, with: punct + " " + pill + (needsSpace ? " " : "")) as NSString
            cited.insert(contentsOf: c.sources, at: 0)
        }
        var seen = Set<Int>()
        return (pillsAtLineEnd(tidy(out as String)), cited.filter { seen.insert($0).inserted }, r.dropped)
    }

    static let pillLink = try! NSRegularExpression(pattern: #"[ \t]*\[[^\]\n]*\]\(antichat-cite://[0-9,]+(?:\?checking)?\)"#)

    /// M7.T16 (pill line break, A-M7-T03a d): MarkdownView lays a paragraph that holds an embedded view out as a flow of
    /// whole runs — the text after a pill is one unbreakable run, so it always starts on a new line. The pills of a
    /// line therefore go to the end of that line (order kept): the text wraps as one run and the pills follow it, as
    /// ChatGPT shows its source chips after the sentence group. Lines inside fenced code are left alone.
    static func pillsAtLineEnd(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            guard !inFence else { return line }
            let ns = line as NSString
            let found = pillLink.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !found.isEmpty else { return line }
            let pills = found.map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
            let rest = pillLink.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            let body = rest.replacingOccurrences(of: "(?<=\\S)  +(?=\\S)", with: " ", options: .regularExpression)
            let trimmed = body.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return trimmed + " " + pills.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// VQ-M11 S-10 (R5): the finished reply as DRAWN — the pills that `pillsAtLineEnd` gathered at the end of a line
    /// become one chip ("site +N", the first source's icon), as ChatGPT shows one citation chip after a sentence group;
    /// four separate domain tags read as a row of their own under the paragraph. The link keeps every pill of the
    /// group (`?g=1_2-3_4`: pills by "_", the sources of one pill by "-"), so the chip still answers for each pill
    /// (probe anchors, hover card, accessibility). `linkify`'s text (one link per pill) is unchanged; only the view
    /// groups. Lines inside fenced code are left alone.
    static func groupedForDisplay(_ text: String) -> String {
        var inFence = false
        return text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            guard !inFence else { return line }
            let ns = line as NSString
            let found = pillLink.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard found.count > 1, let last = found.last, last.range.location + last.range.length == ns.length else { return line }
            // Only a trailing run of pills (nothing but spaces between them) is grouped.
            var run = [last]
            for m in found.dropLast().reversed() {
                let gapStart = m.range.location + m.range.length
                let gap = ns.substring(with: NSRange(location: gapStart, length: run[0].range.location - gapStart))
                guard gap.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                run.insert(m, at: 0)
            }
            guard run.count > 1 else { return line }
            var groups: [[Int]] = [], checking = false, label = ""
            for m in run {
                let link = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
                guard let open = link.range(of: "]("), let url = URL(string: String(link[open.upperBound...].dropLast())) else { return line }
                if label.isEmpty { label = String(link[link.index(after: link.startIndex)..<open.lowerBound]) }
                groups.append(numbers(url))
                checking = checking || self.checking(url)
            }
            var seen = Set<Int>()
            let all = groups.flatMap { $0 }.filter { seen.insert($0).inserted }
            let g = groups.map { $0.map(String.init).joined(separator: "-") }.joined(separator: "_")
            let chip = "[\(label)](\(scheme)://\(all.map(String.init).joined(separator: ","))?g=\(g)\(checking ? "&checking" : ""))"
            let head = ns.substring(to: run[0].range.location).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return head + " " + chip
        }.joined(separator: "\n")
    }

    /// The pills a grouped chip stands for (`?g=`); one group (the link's own numbers) for a plain pill.
    static func groups(_ url: URL) -> [[Int]] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let g = items.first(where: { $0.name == "g" })?.value, !g.isEmpty else { return [numbers(url)] }
        return g.split(separator: "_").map { $0.split(separator: "-").compactMap { Int($0) } }.filter { !$0.isEmpty }
    }

    /// "example.com" / "example.com +2" (brackets and markdown-significant characters stripped).
    static func label(_ sources: [WebSourceRecord]) -> String {
        guard let first = sources.first else { return "" }
        let site = domain(first.site.isEmpty ? (URL(string: first.url)?.host() ?? "") : first.site)
            .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return sources.count > 1 ? "\(site) +\(sources.count - 1)" : site
    }

    static func domain(_ site: String) -> String { site.hasPrefix("www.") ? String(site.dropFirst(4)) : site }

    /// Spaces left before punctuation by a removed marker; doubled spaces around a pill.
    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: " +([.,;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "  +\\[", with: " [", options: .regularExpression)
            .replacingOccurrences(of: "\\)  +", with: ") ", options: .regularExpression)
    }

    /// `antichat-cite://1,3` → [1, 3].
    static func numbers(_ url: URL) -> [Int] {
        guard url.scheme == scheme else { return [] }
        return (url.host() ?? "").split(separator: ",").compactMap { Int($0) }
    }

    /// `antichat-cite://1?checking` → true (M7 bars).
    static func checking(_ url: URL) -> Bool {
        url.scheme == scheme && (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { $0.name == "checking" }
    }

    static func image(_ base64: String?) -> NSImage? {
        guard let img = base64.flatMap({ Data(base64Encoded: $0) }).flatMap(NSImage.init(data:)), usableIcon(img) else { return nil }
        return img
    }

    /// VQ-M10 S-10: an icon that would draw as a sliver or nothing (far from square, or almost all transparent: the
    /// first source's favicon in the capture) falls back to the globe, as the reference shows a neutral glyph.
    static func usableIcon(_ img: NSImage) -> Bool {
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0, max(w, h) / min(w, h) <= 2 else { return false }
        let side = 16
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return true }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        let visible = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 50 }.count
        return visible >= side * side / 8  // at least 1/8 of the square drawn
    }
}

/// MarkdownView renders every `antichat-cite://` link with this view (inline, in the text flow).
struct CitationPillRenderer: MarkdownLinkRenderer {
    func makeBody(configuration: MarkdownLinkRendererConfiguration) -> some View {
        CitationPillView(numbers: CitationPill.numbers(configuration.url), checking: CitationPill.checking(configuration.url),
                         groups: CitationPill.groups(configuration.url))
    }
}

struct CitationPillView: View {
    let numbers: [Int]
    @Environment(\.webSources) private var sources
    /// AT-250 c2 (M7 bars): the reply's citation checks still run after the final write (`?checking` on the link, so
    /// the settled text differs and the renderer redraws); the pill shows `cite.checking` until the verdict.
    var checking = false
    /// VQ-M11 S-10: the pills this chip stands for (`CitationPill.groupedForDisplay`); [] = one pill, `numbers`.
    var groups: [[Int]] = []
    @Environment(\.openURL) private var openURL
    @State private var hovering = false
    @State private var showCard = false

    private var cited: [WebSourceRecord] { numbers.compactMap { n in sources.first { $0.n == n && $0.fetched } } }

    var body: some View {
        let cited = cited
        if let first = cited.first {
            Button {
                if let u = URL(string: first.url) { openURL(u) }
            } label: {
                HStack(spacing: 4) {
                    if checking {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                    } else if let icon = CitationPill.image(first.faviconData) {
                        // VQ-M11 S-10: the source's icon leads the chip, as the reference's citation chip does.
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 12, height: 12)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "globe").font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
                    }
                    Text(verbatim: CitationPill.label(cited))
                }
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(checking ? Color.textTertiary : hovering ? Color.textPrimary : Color.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.textPrimary.opacity(hovering ? 0.14 : 0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        if hovering { showCard = true }
                    }
                }
            }
            .popover(isPresented: $showCard, arrowEdge: .bottom) {
                CitationHoverCard(sources: cited).onHover { if !$0 { showCard = false } }
            }
            .help(checking ? CopyKey("cite.checking").string() : cited.map(\.title).joined(separator: "\n"))
            .accessibilityLabel(Text(verbatim: cited.map { "\($0.title), \(CitationPill.domain($0.site))" }.joined(separator: "; ")
                + (checking ? ", " + CopyKey("cite.checking").string() : "")))
            .accessibilityIdentifier("citation.\(first.n)")
            .background {
                // One probe anchor per pill the chip stands for (a grouped chip answers for each, VQ-M11 S-10).
                ZStack {
                    ForEach(Array((groups.isEmpty ? [numbers] : groups).enumerated()), id: \.offset) { _, g in
                        Color.clear.probeAnchor("citation.\(g.map(String.init).joined(separator: ","))" + (checking ? ".checking" : ""))
                    }
                }
            }
            .fixedSize()
        }
    }
}
