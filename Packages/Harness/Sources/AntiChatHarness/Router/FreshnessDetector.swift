// M7.T05 (R-228, NFR-U12; consumer of the M2 pre-router, G-013): does a prompt probably need information newer than the
// active model knows? Local only, no network. A hit is any of
//   (a) a year (or month + year) in the prompt later than the model's `knowledge_cutoff` ("YYYY-MM");
//   (b) a term of `Resources/router/fresh-terms.json` (today / latest / current / news / price / score / weather + live
//       events, in the 6 router languages), unless a stable guard matches ("explain …", "in Python", "write a poem");
//   (c) the M2 router's `web_needed` prototype score ≥ its fitted threshold (`router_threshold`).
// The term list and thresholds live in the JSON and are tuned only by `antichat-bench fresh-hint` (fresh-vs-stable-200).
import Foundation

public struct FreshnessDetector: Sendable {
    public enum Reason: String, Sendable, Equatable { case date, term, router }

    public struct Config: Decodable, Sendable {
        public var version: Int
        public var router_threshold: Float
        public var terms: [String: [String]]
        public var stable_guards: [String]
        /// Model key prefix → "YYYY-MM" (`default` for an unknown model); see `knowledge_cutoffs_source`.
        public var knowledge_cutoffs: [String: String]?
    }

    /// The active model's knowledge cutoff: the longest key prefix of `modelKey` in `knowledge_cutoffs`, else `default`.
    public func cutoff(forModel modelKey: String) -> String? {
        let table = config.knowledge_cutoffs ?? [:]
        let hit = table.keys.filter { $0 != "default" && modelKey.hasPrefix($0) }.max { $0.count < $1.count }
        return hit.flatMap { table[$0] } ?? table["default"]
    }

    public let config: Config
    let termRegex: [NSRegularExpression]
    let guards: [NSRegularExpression]

    public static let bundled: FreshnessDetector? = {
        guard let url = Bundle.module.url(forResource: "fresh-terms", withExtension: "json"),
              let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return FreshnessDetector(config: c)
    }()

    public init(config: Config) {
        self.config = config
        func rx(_ p: String) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + p + #")(?![\p{L}\p{N}])"#, options: [.caseInsensitive])
        }
        termRegex = config.terms.values.flatMap { $0 }.compactMap(rx)
        guards = config.stable_guards.compactMap(rx)
    }

    /// The first reason `prompt` needs fresh information (nil = stable). `cutoff` = the active model's
    /// `knowledge_cutoff` ("YYYY-MM"); `webNeededScore` = the pre-router's `web_needed` score for this prompt, if scored.
    public func hit(_ prompt: String, cutoff: String?, webNeededScore: Float? = nil) -> Reason? {
        if let cutoff, Self.mentionsLaterDate(prompt, than: cutoff) { return .date }
        let ns = prompt as NSString, all = NSRange(location: 0, length: ns.length)
        let term = termRegex.contains { $0.firstMatch(in: prompt, range: all) != nil }
        if term, !guards.contains(where: { $0.firstMatch(in: prompt, range: all) != nil }) { return .term }
        if let s = webNeededScore, s >= config.router_threshold { return .router }
        return nil
    }

    static let year = try! NSRegularExpression(pattern: #"(?<!\d)(19|20)\d{2}(?!\d)"#)

    /// A four-digit year after the cutoff's year, or the cutoff's year itself when the cutoff is before December
    /// (a question about "2025" asked of a model that stops in 2025-03 may need later facts).
    static func mentionsLaterDate(_ prompt: String, than cutoff: String) -> Bool {
        let parts = cutoff.split(separator: "-").compactMap { Int($0) }
        guard let cy = parts.first else { return false }
        let cm = parts.count > 1 ? parts[1] : 12
        let ns = prompt as NSString
        for m in year.matches(in: prompt, range: NSRange(location: 0, length: ns.length)) {
            guard let y = Int(ns.substring(with: m.range)) else { continue }
            if y > cy || (y == cy && cm < 12) { return true }
        }
        return false
    }
}
