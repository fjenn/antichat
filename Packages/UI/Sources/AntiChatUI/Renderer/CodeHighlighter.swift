// Syntax highlighting for code blocks (M1.T09 step 3; P-shell-04: Highlightr 2.3.0 = highlight.js in JavaScriptCore).
// One Highlightr per theme, created once and used serially off the main actor (MarkdownView's default style builds a
// new JSContext per block and per update; with 3k-token replies that cost would land on every reveal tick).
import AppKit
@preconcurrency import Highlightr
import SwiftUI

actor CodeHighlighter {
    static let shared = CodeHighlighter()

    /// Highlightr theme per appearance (components.md CodeBlock "Highlightr theme per light/dark").
    static func theme(dark: Bool) -> String { dark ? "atom-one-dark" : "xcode" }

    private var engines: [String: Highlightr] = [:]

    private func engine(_ theme: String) -> Highlightr? {
        if let h = engines[theme] { return h }
        guard let h = Highlightr() else { return nil }
        h.setTheme(to: theme)
        engines[theme] = h
        return h
    }

    /// Canonical highlight.js language names (aliases such as `py`, `sh`, `zsh`, `js` resolve inside highlight.js).
    func supportedLanguages() -> [String] { engine(Self.theme(dark: false))?.supportedLanguages() ?? [] }

    /// Colour runs for `code` in `language` (nil / unknown → plain text, never auto-detected: a wrong guess paints
    /// prose as code). Fonts are stripped: the block sets the `type.code` token font.
    func highlight(_ code: String, language: String?, dark: Bool) -> AttributedString? {
        guard let language = language?.lowercased(), !language.isEmpty, !code.isEmpty,
            let h = engine(Self.theme(dark: dark)), Self.knows(language, in: h)
        else { return nil }
        guard let out = h.highlight(code, as: language) else { return nil }
        let m = NSMutableAttributedString(attributedString: out)
        let all = NSRange(location: 0, length: m.length)
        m.removeAttribute(.font, range: all)
        m.removeAttribute(.backgroundColor, range: all)
        return try? AttributedString(m, including: \.appKit)
    }

    /// `highlight(_:as:)` falls back to auto-detection for a name highlight.js does not know, so unknown fences
    /// stay plain: canonical names (`listLanguages`) plus the aliases of the bundled highlight.js 11.11.1.
    private static func knows(_ language: String, in h: Highlightr) -> Bool {
        aliases.contains(language) || h.supportedLanguages().contains(language)
    }

    /// Every alias of highlight.js 11.11.1 (Highlightr 2.3.0 bundle) that is not itself a canonical name.
    static let aliases: Set<String> = [
        "ado", "adoc", "ahk", "apacheconf", "arm", "as", "asc", "atom", "bat", "bf", "bind", "c#", "c++", "capnp",
        "cc", "cjs", "clj", "cls", "cmake.in", "cmd", "coffee", "console", "cr", "craftcms", "crm", "cs", "cson",
        "cts", "cxx", "dcl", "dfm", "do", "docker", "dpr", "dst", "edn", "erl", "ex", "exs", "f#", "f90", "f95",
        "feature", "fs", "gemspec", "gms", "golang", "gql", "graph", "gss", "gyp", "h", "h++", "hbs", "hh", "hpp",
        "hs", "html", "html.handlebars", "html.hbs", "htmlbars", "https", "hx", "hxx", "hylang", "i7", "iced", "icl",
        "ino", "instances", "ipython", "irb", "jinja", "jldoctest", "js", "jsonc", "jsp", "jsx", "k", "kdb", "kt",
        "kts", "lassoscript", "ls", "m", "mak", "make", "md", "mikrotik", "mips", "mjs", "mk", "mkd", "mkdown", "ml",
        "mm", "mma", "moo", "moon", "mts", "nc", "nginxconf", "nixos", "nt", "obj-c", "obj-c++", "objc",
        "objective-c++", "osascript", "p21", "pas", "pascal", "patch", "pb", "pbi", "pcmk", "pde", "pf.conf", "pl",
        "plist", "pluto", "pm", "podspec", "postgres", "postgresql", "pp", "proto", "ps", "ps1", "pwsh", "py",
        "pycon", "qt", "rb", "re", "rs", "rss", "scad", "sci", "scm", "sh", "shellsession", "st", "stanfuncs",
        "step", "stp", "styl", "sv", "svg", "svh", "tao", "tex", "text", "thor", "tk", "toml", "ts", "tsx", "txt",
        "v", "vb", "vbs", "wildfly-cli", "wl", "wsf", "x++", "xhtml", "xjb", "xls", "xlsx", "xpath", "xq", "xqm",
        "xsd", "xsl", "yml", "zep", "zone", "zsh",
    ]

    /// Number of distinct foreground colours (LanguageCoverageTests: "token colour runs > 1").
    static func colourCount(_ s: AttributedString) -> Int {
        var colours = Set<String>()
        for run in s.runs {
            if let c = run.appKit.foregroundColor?.usingColorSpace(.sRGB) {
                colours.insert(String(format: "%.3f %.3f %.3f", c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return colours.count
    }
}
