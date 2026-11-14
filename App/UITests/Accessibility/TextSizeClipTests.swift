// AT-223 part 2 / AT-NFR-A4 (M9.T02 step 6): at 12, 14, 18 and 24 pt (the Settings stepper) and DEBUG
// `-TextSizeScale 2.0`, no static text or button on the primary screens leaves its window or reports truncation.
import XCTest

final class TextSizeClipTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    static func clipped(_ app: XCUIApplication) -> [String] {
        let window = app.windows.firstMatch
        let bounds = window.frame
        var bad: [String] = []
        for t in [XCUIElement.ElementType.staticText, .button] {
            for e in window.descendants(matching: t).allElementsBoundByIndex where e.exists && e.isHittable {
                if !bounds.contains(e.frame) { bad.append("outside: \(e.identifier) '\(e.displayText)'") }
                if Self.truncated(e.displayText) { bad.append("truncated: \(e.identifier) '\(e.displayText)'") }
            }
        }
        return bad
    }

    /// Copy that ends in "…" by design ("Make a picture of…", "Creating {filename}…"): the copy deck's English strings,
    /// placeholders as wildcards. Only a label ending in "…" that is none of them (nor a repetition of one, the
    /// double-length pseudo-locale) was cut short (Q-015 r2: the `sugg.image` card's own ellipsis was reported).
    static let ellipsisCopy: [NSRegularExpression] = {
        let deck = TurnApp.repoRoot.appendingPathComponent("Packages/Design/Sources/AntiChatDesign/Copy/CopyDeck.swift")
        guard let text = try? String(contentsOf: deck, encoding: .utf8),
              let line = try? NSRegularExpression(pattern: #"^\s*"[^"]+": "(.*…)",$"#, options: .anchorsMatchLines)
        else { return [] }
        return line.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            let parts = String(text[r]).replacingOccurrences(of: #"\{[^}]*\}"#, with: "\u{1}", options: .regularExpression)
                .components(separatedBy: "\u{1}").map(NSRegularExpression.escapedPattern(for:))
            return try? NSRegularExpression(pattern: "^(?:" + parts.joined(separator: ".*") + #"\s*)+$"#)
        }
    }()

    static func truncated(_ label: String) -> Bool {
        guard label.hasSuffix("…") else { return false }
        let r = NSRange(label.startIndex..., in: label)
        return !ellipsisCopy.contains { $0.firstMatch(in: label, range: r) != nil }
    }

    @MainActor func run(_ args: [String], _ name: String) {
        let app = A11y.launch(args + ["-ReportTruncation", "YES"])
        var report: [String: [String]] = ["S-05": Self.clipped(app)]
        A11y.sendOneTurn(app)
        report["S-08"] = Self.clipped(app)
        A11y.write(report, "build/at/AT-223/clip-\(name).json")
        for (screen, bad) in report { XCTAssertEqual(bad, [], "\(name) \(screen)") }
    }

    @MainActor func test12pt() { run(["-textSize", "12"], "12pt") }
    @MainActor func test14pt() { run(["-textSize", "14"], "14pt") }
    @MainActor func test18pt() { run(["-textSize", "18"], "18pt") }
    @MainActor func test24pt() { run(["-textSize", "24"], "24pt") }
    @MainActor func testScale200() { run(["-TextSizeScale", "2.0"], "scale2") }
    /// M9.T04 step 4: double-length pseudo-locale and forced RTL layout on the same screens.
    @MainActor func testPseudoDoubleLength() { run(["-NSDoubleLocalizedStrings", "YES"], "double") }
    @MainActor func testForcedRTL() { run(["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"], "rtl") }
}
