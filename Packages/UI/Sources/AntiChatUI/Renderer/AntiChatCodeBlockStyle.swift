// CodeBlock (components.md §3; M1.T09 step 3): header with the fence's language label, a wrap toggle and Copy
// (`msg.copy` → `msg.copied` for 1.5 s); Highlightr body with a light/dark theme; horizontal scroll unless wrapped;
// collapsed after 40 lines with "Show all". While the reply streams only completed lines are highlighted, and
// highlighting only changes colours (same font, same glyphs), so it never moves text (no re-highlight jumps).
// Fenced `mermaid` blocks render in MermaidBlockView instead; M6.T13 promoted blocks → ArtifactCardView (LongOutputPromoter).
import AntiChatDesign
import AppKit
import MarkdownView
import SwiftUI

struct AntiChatCodeBlockStyle: MarkdownCodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        // M6.T13 (R-016 AC1): promoted blocks show their artifact card once the reply is done.
        if let block = LongOutputPromoter.promotion(language: configuration.language, code: configuration.code) {
            PromotedBlockView(block: block) { inline(configuration) }
        } else {
            inline(configuration)
        }
    }

    @ViewBuilder private func inline(_ configuration: Configuration) -> some View {
        if configuration.language?.lowercased() == "mermaid" {
            MermaidBlockView(source: configuration.code)
        } else {
            CodeBlockView(language: configuration.language, code: configuration.code)
        }
    }
}

// The enclosing block is still streaming (code blocks highlight completed lines only; Mermaid waits for done):
// `EnvironmentValues.markdownStream` (StreamingMarkdownBinder.swift), one flag per block.

struct CodeBlockView: View {
    let language: String?
    let code: String

    static let collapsedLines = 40

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.markdownStream) private var stream  // fix/t05-u5-part5: the block's own flag (observed)
    private var streaming: Bool { stream?.streaming ?? false }
    @Environment(\.displayScale) private var displayScale
    @Environment(\.pasteboard) private var pasteboard
    @State private var wrap = false
    @State private var expanded = false
    @State private var copied = false
    @State private var highlighted: Highlighted?

    struct Highlighted: Equatable {
        var source: String
        var dark: Bool
        var text: AttributedString
    }

    struct HighlightKey: Equatable {
        var source: String
        var language: String?
        var dark: Bool
    }

    /// The trailing newline of a fence body is not part of the code.
    private var body_: String { code.hasSuffix("\n") ? String(code.dropLast()) : code }
    var lineCount: Int { Self.lineCount(body_) }
    static func lineCount(_ code: String) -> Int { code.reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
    private var collapsed: Bool { !expanded && lineCount > Self.collapsedLines }
    private var dark: Bool { colorScheme == .dark }

    /// What gets highlighted: everything once done; up to the last newline while streaming.
    var highlightSource: String { Self.highlightSource(body_, streaming: streaming) }

    static func highlightSource(_ code: String, streaming: Bool) -> String {
        guard streaming else { return code }
        guard let nl = code.lastIndex(of: "\n") else { return "" }
        return String(code[..<nl])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.borderSubtle)
            codeBody
                .padding(.horizontal, Spacing.space4)
                .padding(.vertical, Spacing.space3)
            if lineCount > Self.collapsedLines {
                Button {
                    expanded.toggle()
                } label: {
                    Text(expanded
                        ? CopyText(CopyKey("code.showLess"))
                        : CopyText(CopyKey("code.showAll"), ["lines": "\(lineCount)"]))
                        .typeStyle(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.space2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .probeID("codeShowAll")
            }
        }
        .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.borderSubtle, lineWidth: Stroke.hairline(scale: displayScale)))
        .accessibilityElement(children: .contain)
        .probeID("codeBlock")
        .task(id: HighlightKey(source: highlightSource, language: language, dark: dark)) {
            let source = highlightSource
            guard !source.isEmpty else { return }
            if let h = highlighted, h.source == source, h.dark == dark { return }
            let lang = language
            let dark = dark
            guard let text = await CodeHighlighter.shared.highlight(source, language: lang, dark: dark),
                !Task.isCancelled
            else { return }
            highlighted = Highlighted(source: source, dark: dark, text: text)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.space3) {
            // No label for a fence without a language (or "text"): "text" over a line of output says nothing.
            Text(verbatim: ["", "text", "plaintext", "plain", "txt"].contains(language?.lowercased() ?? "") ? "" : language!)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textSecondary)
                .probeID("codeLanguage")
            Spacer(minLength: Spacing.space2)
            Button {
                wrap.toggle()
            } label: {
                Image(systemName: wrap ? "arrow.left.and.right.text.vertical" : "text.word.spacing")
                    .foregroundStyle(wrap ? Color.textPrimary : Color.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(CopyKey("code.wrap")))
            .accessibilityLabel(Text(CopyKey("code.wrap")))
            .accessibilityValue(Text(verbatim: wrap ? "1" : "0"))
            .probeID("codeWrap")
            Button(action: copy) {
                Label {
                    Text(CopyKey(copied ? "msg.copied" : "msg.copy"))
                } icon: {
                    Image(systemName: copied ? "checkmark" : "square.on.square")
                }
                .labelStyle(.titleAndIcon)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .probeID("codeCopy")
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space2)
    }

    @ViewBuilder private var codeBody: some View {
        let text = Text(displayed).typeStyle(.code).foregroundStyle(Color.textPrimary).textSelection(.enabled)
        if wrap {
            text.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal) {
                text.fixedSize(horizontal: true, vertical: true)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The highlighted prefix (when it still matches) + the not-yet-highlighted rest, cut after 40 lines if collapsed.
    var displayed: AttributedString {
        let full = body_
        var out: AttributedString
        if let h = highlighted, h.dark == dark, full.hasPrefix(h.source) {
            out = h.text
            out.append(AttributedString(String(full.dropFirst(h.source.count))))
        } else {
            out = AttributedString(full)
        }
        guard collapsed else { return out }
        var lines = 0
        var cut = out.endIndex
        for i in out.characters.indices where out.characters[i] == "\n" {
            lines += 1
            if lines == Self.collapsedLines { cut = i; break }
        }
        return AttributedString(out[out.startIndex..<cut])
    }

    private func copy() {
        pasteboard.clearContents()
        pasteboard.setString(body_, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
