// AT-250 c2 attempt 6 (R-250 AC2, A-M7-T03c, lead decision 2026-11-08): the generative citation verifier, the last
// stage of the citation check at finalize (after the deterministic CitationGrounding and the MiniCheck entailment).
// For the citation markers still standing, the tier's own chat model (already loaded, through the engine the turn
// uses) is asked whether the cited sources' text the answering model saw — the windows sharing most words with each
// sentence — state every detail of the sentence. A verdict other than SUPPORTED removes the marker; the sentence keeps
// its words, uncited (the copy rule: a pill only stands for what its passage says; R-241: no word of the answer
// changes, nothing is filtered or rewritten).
// Attempt 7: the sentences go in batches of `batchSize` per request (each cited source's windows printed once, one
// verdict line per sentence), so a long answer is verified inside the bound; attempt 6 asked one request per sentence
// and ran out of time on T3 list answers (199 markers unverified on the held-out set). M7 bars: no whole-answer bound by default (`budget` nil), each batch has a time limit, and the pass runs after the final write (pills show the checking state); a batch not
// finished in time keeps the earlier result for its sentences. Tuned on dev labels only (attempt-4/5).
// M7 verifier (2026-11-10): every cited sentence gets a verdict or loses its pill. A batch's verdict budget was 14
// tokens per sentence; one long "UNSUPPORTED: <detail>" line used it up and the later sentences of the batch got no
// line, so their markers stayed unverified (and kept their pills). Now the budget is `tokensPerSentence` (64: the
// longest verdict line seen on the dev replays is ≈ 230 characters) per sentence, a sentence still without a line is
// asked again on its own, and a marker that has no verdict at the end (no line, time limit, generator error,
// cancelled) is removed like an UNSUPPORTED one: a pill only stands for a sentence the verifier said SUPPORTED to.
// There is no sentence cap any more (the pass runs after the final write).
import Foundation

public enum CitationVerifier {
    /// The chat model's completion of `prompt` (greedy, at most `maxTokens`, reasoning off).
    public typealias Generator = @Sendable (_ prompt: String, _ maxTokens: Int) async throws -> String

    /// Windows per sentence (characters, over its cited sources); a batch prints the union once per source.
    public static let passageChars = 1600
    /// Window size (characters, cut at sentence ends where possible).
    public static let windowChars = 600
    /// Sentences per request, and verdict tokens per sentence ("3: UNSUPPORTED: <detail>"; the budget of a request
    /// is `tokens(count:)`, so a long detail line never leaves the later sentences of its batch without a verdict).
    public static let batchSize = 8
    public static let tokensPerSentence = 64
    /// The verdict budget of a request of `count` sentences.
    public static func tokens(count: Int) -> Int { tokensPerSentence * count + 8 }
    /// Whole-answer bound: none (M7 bars, lead decision 2026-11-09). Attempt 7's 12 s bound cut 21 held-out-2 T3
    /// answers under shared load and 47 of the 55 T3 misses sat in them (0.875; 0.934 unbounded). The pass runs after
    /// the final write, off the answer's critical path; its pills show the checking state until it ends.
    public static let budget: Duration? = nil
    /// Time limit per batch request (a stuck engine): past it the batch has no verdict; its sentences are asked again
    /// one by one, and a sentence still without a verdict loses its marker. Far above any measured batch (attempt 7 max 12.1 s per whole T3 answer at load 46).
    public static let batchTimeout: Duration = .seconds(120)

    public struct Result: Sendable, Equatable {
        public var text: String
        /// Markers verified (a verdict) / removed for an UNSUPPORTED verdict / removed for having no verdict (budget,
        /// time limit, generator error, cancelled; `uncited` does not count these); `retried` = sentences asked again
        /// alone after their batch reply had no line for them.
        public var checked: Int
        public var uncited: Int
        public var unverified: Int
        public var retried = 0
        /// Wall time of the whole pass (ms) and per finished batch (ms), for the bench and the log.
        public var millis: Double
        public var sentenceMillis: [Double]
        /// nil = ran; else why not (generator error text, no content).
        public var skipped: String?
    }

    // MARK: Prompt

    /// The rules of attempt 6's dev-tuned single-sentence prompt v2 (what counts against a sentence, what does not,
    /// three short examples), for a numbered list of sentences. The fixed part comes first (prefix cache).
    public static let template = """
        You check whether sentences of an answer are backed by the sources they cite.

        A sentence is SUPPORTED if every fact it states is in the sources it cites: its names, numbers, dates, list items, places and roles, and words such as only, main, first, latest, most recent, next, always, widely, over, official. Rewording is fine. A pronoun or a short heading that refers to the topic is fine. Leaving out details of the sources is fine.

        A sentence is UNSUPPORTED if it adds a fact, name, list item or detail its sources do not give, makes a qualifier stronger or different, calls something latest, most recent, next or current when the sources do not, or ties a number, date or name to a different thing than the sources do.

        Examples:
        Source: "Firefox 150 was released on May 5. Firefox 149 came out in April."
        "The latest Firefox is version 150, released on May 5." → UNSUPPORTED: latest
        "Firefox 150 came out on May 5." → SUPPORTED
        Source: "Penicillin is used against infections such as pneumonia."
        "Penicillin treats pneumonia and syphilis." → UNSUPPORTED: syphilis

        SOURCES:
        {{SOURCES}}

        SENTENCES:
        {{SENTENCES}}

        Check each sentence only against the sources it cites. Answer with exactly {{COUNT}} lines, in order, each "<number>: SUPPORTED" or "<number>: UNSUPPORTED: <detail>".
        """

    /// The design knobs (the bench's dev tuning passes other values; the app uses `standard`).
    public struct Config: Sendable {
        public var passageChars = CitationVerifier.passageChars
        public var batchSize = CitationVerifier.batchSize
        public var budget: Duration? = CitationVerifier.budget
        public var batchTimeout = CitationVerifier.batchTimeout
        public var template = CitationVerifier.template
        public init() {}
        public static let standard = Config()
    }

    public static func prompt(sentences: String, sources: String, count: Int, template: String = template) -> String {
        template.replacingOccurrences(of: "{{SOURCES}}", with: sources).replacingOccurrences(of: "{{SENTENCES}}", with: sentences)
            .replacingOccurrences(of: "{{COUNT}}", with: String(count))
    }

    /// true = supported, false = not, nil = no verdict.
    public static func verdict(_ output: String) -> Bool? {
        let t = output.replacingOccurrences(of: #"<think>[\s\S]*?(?:</think>|$)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"^[*_`"'\s]+"#, with: "", options: .regularExpression)
            .uppercased()
        if t.hasPrefix("SUPPORTED") { return true }
        if t.hasPrefix("MISSING") || t.hasPrefix("NOT SUPPORTED") || t.hasPrefix("UNSUPPORTED") || t.hasPrefix("PARTIAL") { return false }
        return nil
    }

    // MARK: Windows

    static let stop: Set<String> = CitationGrounding.function.union(CitationGrounding.common)

    /// The sentence's claim tokens: numbers and content words (≥ 3 letters, not function words), lowercased.
    static func tokens(_ s: String) -> Set<String> {
        let n = CitationGrounding.normalize(s)
        return Set(n.split { !($0.isLetter || $0.isNumber) }.map(String.init)
            .filter { ($0.first?.isNumber ?? false) || ($0.count >= 3 && !stop.contains($0)) })
    }

    /// Windows of `text` of about `windowChars`, cut after a sentence end where one falls in the second half.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.count <= windowChars { out.append(String(rest)); break }
            let hard = rest.index(rest.startIndex, offsetBy: windowChars)
            let half = rest.index(rest.startIndex, offsetBy: windowChars / 2)
            var cut = hard
            if let r = rest[half..<hard].range(of: #"[.!?]\s"#, options: [.regularExpression, .backwards]) { cut = r.upperBound }
            out.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    struct Window: Hashable { var src: Int; var idx: Int }

    /// The windows of `sources` (index into `sources`, window number) sharing most claim tokens with `sentence`
    /// (numbers count double), best first across sources, at most `chars` in all; plus each source's header line
    /// ("title — site") and windows.
    static func pick(sentence: String, sources: [(n: Int, text: String)], chars: Int) -> (picks: [Window], headers: [Int: String], windows: [[String]]) {
        let want = tokens(sentence)
        var scored: [(Window, Double, Int)] = [], headers: [Int: String] = [:], windows: [[String]] = []
        for (si, s) in sources.enumerated() {
            var body = s.text
            if let nl = body.firstIndex(of: "\n"), body.distance(from: body.startIndex, to: nl) <= 200 {
                headers[si] = String(body[..<nl]); body = String(body[body.index(after: nl)...])
            }
            let ws = split(body)
            windows.append(ws)
            for (i, w) in ws.enumerated() {
                let hit = want.intersection(tokens(w))
                let score = hit.reduce(0.0) { $0 + (($1.first?.isNumber ?? false) ? 2 : 1) }
                scored.append((Window(src: si, idx: i), score - Double(i) * 0.001, w.count))  // ties: earlier first
            }
        }
        var used = 0
        var picks: [Window] = []
        for (w, _, n) in scored.sorted(by: { $0.1 > $1.1 }) {
            if used + n > chars, !picks.isEmpty { continue }
            picks.append(w); used += n
        }
        return (picks, headers, windows)
    }

    /// `[n] header` then the picked windows of each source in text order ("…" between windows that are not adjacent).
    static func render(sources: [(n: Int, text: String)], picks: Set<Window>, headers: [Int: String], windows: [[String]]) -> String {
        var out: [String] = []
        for (si, s) in sources.enumerated() {
            let ws = picks.filter { $0.src == si }.map(\.idx).sorted()
            guard !ws.isEmpty || headers[si] != nil else { continue }
            var block = "[\(s.n)]" + (headers[si].map { " " + $0 } ?? "")
            var prev: Int?
            for i in ws {
                let gap = prev.map { $0 == i - 1 ? " " : "\n… " } ?? (headers[si] == nil ? " " : "\n")
                block += gap + windows[si][i]
                prev = i
            }
            out.append(block)
        }
        return out.joined(separator: "\n\n")
    }

    /// The passage for one sentence (its cited sources' best windows, at most `chars`).
    public static func passage(sentence: String, sources: [(n: Int, text: String)], chars: Int = passageChars) -> String {
        let p = pick(sentence: sentence, sources: sources, chars: chars)
        return render(sources: sources, picks: Set(p.picks), headers: p.headers, windows: p.windows)
    }

    // MARK: Batches

    /// One sentence to verify: its text and its cited sources (number, the text the model saw).
    public struct Item: Sendable {
        public var sentence: String
        public var sources: [(n: Int, text: String)]
        public init(sentence: String, sources: [(n: Int, text: String)]) { self.sentence = sentence; self.sources = sources }
    }

    /// The prompt for a batch: the union of the sentences' best windows per source (each source once), then the
    /// numbered sentences with the sources each cites.
    public static func batchPrompt(_ items: [Item], config: Config = .standard) -> String {
        let chars = config.passageChars
        var order: [Int] = [], texts: [Int: String] = [:]
        for it in items { for s in it.sources where texts[s.n] == nil { order.append(s.n); texts[s.n] = s.text } }
        let all = order.map { (n: $0, text: texts[$0]!) }
        var picks = Set<Window>(), headers: [Int: String] = [:], windows: [[String]] = []
        for it in items {
            let p = pick(sentence: it.sentence, sources: all.filter { s in it.sources.contains { $0.n == s.n } }, chars: chars)
            // map the item's source indices back to `all`
            let local = all.filter { s in it.sources.contains { $0.n == s.n } }
            for w in p.picks { picks.insert(Window(src: order.firstIndex(of: local[w.src].n)!, idx: w.idx)) }
        }
        for (si, s) in all.enumerated() {
            let p = pick(sentence: "", sources: [s], chars: 0)
            if let h = p.headers[0] { headers[si] = h }
            windows.append(p.windows[0])
        }
        let sourcesText = render(sources: all, picks: picks, headers: headers, windows: windows)
        let list = items.enumerated().map { k, it in
            "\(k + 1). [cites " + it.sources.map { String($0.n) }.joined(separator: ",") + "] " + it.sentence
        }.joined(separator: "\n")
        return prompt(sentences: list, sources: sourcesText, count: items.count, template: config.template)
    }

    /// Per sentence of a batch reply: true = supported, false = not, nil = no line for it.
    public static func parseBatch(_ output: String, count: Int) -> [Bool?] {
        var out = [Bool?](repeating: nil, count: count)
        let t = output.replacingOccurrences(of: #"<think>[\s\S]*?(?:</think>|$)"#, with: "", options: .regularExpression)
        for line in t.split(whereSeparator: \.isNewline) {
            guard let m = line.firstMatch(of: /^[\s*_]*(\d{1,2})[\s*_]*[:.)\-–]+\s*(.*)$/), let k = Int(m.output.1), k >= 1, k <= count
            else { continue }
            if out[k - 1] == nil { out[k - 1] = verdict(String(m.output.2)) }
        }
        return out
    }

    /// Verdicts for `items` in one request (nil = no verdict: no line, deadline, or generator error).
    public static func verifyBatch(_ items: [Item], deadline: ContinuousClock.Instant, config: Config = .standard,
                                   generate: @escaping Generator) async throws -> [Bool?] {
        let q = batchPrompt(items, config: config)
        let maxTokens = tokens(count: items.count)
        let reply: String? = try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await generate(q, maxTokens) }
            group.addTask { try? await Task.sleep(until: deadline, clock: .continuous); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return reply.map { parseBatch($0, count: items.count) } ?? Array(repeating: nil, count: items.count)
    }

    // MARK: Apply

    /// Awaited before each batch request: the app holds the pass while a turn of the chat is generating, so the
    /// verifier never delays an answer's text (nil = no wait; the bench).
    public typealias Gate = @Sendable () async -> Void

    public static func apply(_ text: String, evidence: [Int: String], config: Config = .standard, beforeBatch: Gate? = nil,
                             generate: @escaping Generator) async -> Result {
        let batchSize = config.batchSize
        let ns = text as NSString
        // Markers outside fenced and inline code only (M7.T16 review #1: `arr[1]` in code is never a citation).
        let matches = CitationGrounding.markers(in: text)
        var result = Result(text: text, checked: 0, uncited: 0, unverified: 0, millis: 0, sentenceMillis: [], skipped: nil)
        guard !matches.isEmpty else { return result }
        let start = ContinuousClock.now
        let deadline = config.budget.map { start + $0 }
        // 1. the markers to verify (claim + cited sources with evidence)
        var items: [Item] = [], itemOf: [Int: Int] = [:]
        var lastEnd = 0
        for (mi, m) in matches.enumerated() {
            let before = ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            lastEnd = m.range.location + m.range.length
            let claim = CitationGrounding.lastSentence(before)
            let known = ns.substring(with: m.range).matches(of: /\d{1,3}/).compactMap { Int($0.output) }.filter { evidence[$0] != nil }
            guard claim.count > 1, !known.isEmpty else { continue }
            itemOf[mi] = items.count
            items.append(Item(sentence: claim, sources: known.map { ($0, evidence[$0]!) }))
        }
        // 2. batches, in order, inside the bound; then every sentence its batch left without a verdict, alone
        var verdicts = [Bool?](repeating: nil, count: items.count)
        let live = { deadline.map({ ContinuousClock.now < $0 }) ?? true }
        func run(_ idx: [Int]) async {
            guard live(), result.skipped == nil, !Task.isCancelled else { return }
            if let beforeBatch { await beforeBatch() }
            let t0 = ContinuousClock.now
            let batchDeadline = min(deadline ?? .now + config.batchTimeout, ContinuousClock.now + config.batchTimeout)
            do {
                let v = try await verifyBatch(idx.map { items[$0] }, deadline: batchDeadline, config: config, generate: generate)
                for (k, x) in v.enumerated() { verdicts[idx[k]] = x }
                if v.contains(where: { $0 != nil }) { result.sentenceMillis.append(millis(ContinuousClock.now - t0)) }
            } catch {
                result.skipped = "generator: \(error)"
            }
        }
        var b = 0
        while b < items.count {
            await run(Array(b..<min(items.count, b + batchSize)))
            b += batchSize
        }
        if batchSize > 1 {
            for k in items.indices where verdicts[k] == nil {
                result.retried += 1
                await run([k])
            }
        }
        // 3. rewrite the markers (no verdict = no pill)
        var out = "", cursor = 0
        for (mi, m) in matches.enumerated() {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let markerText = ns.substring(with: m.range)
            guard let k = itemOf[mi] else { out += markerText; continue }
            guard let ok = verdicts[k] else { result.unverified += 1; continue }
            result.checked += 1
            if ok { out += markerText } else { result.uncited += 1 }
        }
        out += ns.substring(from: cursor)
        result.text = out
        result.millis = millis(ContinuousClock.now - start)
        return result
    }

    static func millis(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
