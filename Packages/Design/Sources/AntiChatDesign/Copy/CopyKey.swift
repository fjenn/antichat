// Copy keys (copy-deck.md; PRD §1.4 / M1.md convention 6). Hand-written; the string table is generated.
import Foundation
import SwiftUI

/// A copy-deck key. Deliberately not `ExpressibleByStringLiteral`: every key in code is spelled
/// `CopyKey("…")`, which `tools/ci/copy-sync.py` checks against copy-deck.md and Localizable.xcstrings.
public struct CopyKey: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    /// The display string: the app's Localizable.xcstrings (translations) first, then the copy-deck English,
    /// with `{name}` placeholders replaced from `args`. An unknown key returns the key itself (copy-sync makes
    /// that a CI failure, so it never ships).
    public func string(_ args: [String: String] = [:]) -> String {
        let english = CopyDeck.english[rawValue] ?? rawValue
        var s: String
        if let plural = CopyDeck.plurals[rawValue], let n = Self.count(args[plural.arg]) {
            s = Self.plural(rawValue, n: n, english: english, one: plural.one, arg: plural.arg)
        } else {
            s = Bundle.main.localizedString(forKey: rawValue, value: english, table: nil)
        }
        for (name, value) in args {
            s = s.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return s
    }

    /// The count in a placeholder value ("1,204" → 1204); nil when it holds no digits.
    static func count(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.filter(\.isASCII).filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    /// A count string (M9.T04 step 5): the catalog's plural variation (`%lld` = the count) formatted with the
    /// language's CLDR rules, else the English one/other pair. The placeholder value itself is substituted later,
    /// so the visible number keeps the caller's formatting ("1,204").
    static func plural(_ key: String, n: Int, english: String, one: String, arg: String) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: "\u{1}", table: nil)
        if format != "\u{1}", format.contains("%") || !format.contains("{\(arg)}") {
            let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            var out = String(format: format, locale: locale, n)
            // The %lld became the bare number; turn it back into the placeholder so caller formatting wins.
            if let r = out.range(of: String(n)) { out.replaceSubrange(r, with: "{\(arg)}") }
            return out
        }
        return n == 1 ? one : english
    }

    /// Whether copy-deck.md has this key.
    public var isKnown: Bool { CopyDeck.english[rawValue] != nil }
}

/// A key plus its placeholder values: what components take for visible text.
public struct CopyText: Hashable, Sendable {
    public let key: CopyKey
    public let args: [String: String]

    public init(_ key: CopyKey, _ args: [String: String] = [:]) {
        self.key = key
        self.args = args
    }

    public var string: String { key.string(args) }
}

public extension Text {
    /// `Text` for a copy key (verbatim: the lookup already happened in `CopyKey.string`).
    init(_ copy: CopyText) { self.init(verbatim: copy.string) }
    init(_ key: CopyKey) { self.init(verbatim: key.string()) }
}
