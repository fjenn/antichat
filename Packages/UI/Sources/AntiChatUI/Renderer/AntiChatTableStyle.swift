// Table (components.md §3; M1.T09 step 4): the Markdown table in a horizontal ScrollView (wide tables never widen the
// reading column) with "Copy as CSV". MarkdownView's table configuration carries views, not text, so the CSV comes
// from the reply's source: the table's position among the reply's tables (by its y in the reply) picks the n-th
// table of the latest parse (`MarkdownRenderContext`), at click time.
import AntiChatDesign
import AppKit
import MarkdownView
import SwiftUI

/// Per reply: the latest Markdown source and where each rendered table sits. Not observed (nothing re-renders).
/// The coordinate space of one rendered reply (tables report their y in it).
let markdownSpace = "antichatMarkdown"

@MainActor
final class MarkdownRenderContext {
    var source = ""
    private var tableY: [UUID: CGFloat] = [:]

    func place(table id: UUID, y: CGFloat) { tableY[id] = y }
    func remove(table id: UUID) { tableY[id] = nil }

    /// CSV of the table registered as `id` (its rank by y among the reply's tables).
    func csv(table id: UUID) -> String? {
        guard let y = tableY[id] else { return nil }
        let index = tableY.values.filter { $0 < y }.count
        let tables = MarkdownBlocks.tables(in: source)
        return tables.indices.contains(index) ? MarkdownBlocks.csv(tables[index]) : nil
    }
}

extension EnvironmentValues {
    @Entry var markdownRenderContext: MarkdownRenderContext? = nil
}

struct AntiChatTableStyle: MarkdownTableStyle {
    func makeBody(configuration: Configuration) -> some View {
        TableBlockView(configuration: configuration)
    }
}

private struct TableBlockView: View {
    let configuration: MarkdownTableStyleConfiguration
    @Environment(\.markdownRenderContext) private var context
    /// The reply block this table renders (nil outside a reply): its source keys the rows.
    @Environment(\.markdownBlock) private var block
    @Environment(\.displayScale) private var displayScale
    @Environment(\.pasteboard) private var pasteboard
    @State private var id = UUID()
    @State private var copied = false

    /// The grid's natural width: the block hugs it (up to the column), so "Copy as CSV" sits at the table's own top
    /// right corner, not at the far edge of the reading column (VQ round 65, S-08: "detached from its table").
    @State private var tableWidth: CGFloat?

    /// Up to six columns wrap their text to fit the reading column (as ChatGPT does); wider tables keep their natural
    /// width and scroll sideways. Unknown shape (a table inside a list or quote) scrolls.
    private var wraps: Bool {
        guard let first = block?.source.split(separator: "\n").first else { return false }
        let cells = first.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: true).count
        return (1...6).contains(cells)
    }

    private var grid: some View {
        // fix/t05-u5-part6 (NFR-U5): the header and each body row are kept while their Markdown line is unchanged.
        // The configuration's rows hold type-erased cells built by each parse, which never compare equal, so
        // every new row of a streaming table rebuilt every row and cell (`StreamingBlocksTests`: rows 1…12
        // re-evaluated for the 12th). The grid still lays out all rows, so column widths are unchanged.
        let keys = TableRowKeys(source: block?.source, rows: configuration.table.rows.count)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            TableRowView(key: keys.header) { configuration.table.header }
            ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { i, row in
                TableRowView(key: keys.row(i)) { row }
            }
        }
        .markdownTableCellPadding(.vertical, Spacing.space2)
        .markdownTableCellPadding(.horizontal, Spacing.space3)
        .markdownTableCellOverlay {
            Rectangle().strokeBorder(Color.borderSubtle, lineWidth: Stroke.hairline(scale: displayScale))
        }
    }

    var body: some View {
        Group {
            if wraps {
                // No scroll view: the stack hugs the grid, so "Copy as CSV" sits at the table's own top right corner.
                VStack(alignment: .trailing, spacing: Spacing.space1) {
                    copyButton
                    grid.fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .trailing, spacing: Spacing.space1) {
                    copyButton
                    ScrollView(.horizontal) {
                        grid.fixedSize(horizontal: true, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                                if tableWidth != w { tableWidth = w }
                            }
                    }
                    .scrollIndicators(.automatic)
                }
                .frame(maxWidth: tableWidth, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(markdownSpace)).minY } action: { y in
            context?.place(table: id, y: y)
        }
        .onDisappear { context?.remove(table: id) }
        .accessibilityElement(children: .contain)
        .probeID("markdownTable")
    }

    private var copyButton: some View {
        Button(action: copyCSV) {
            Label {
                Text(CopyKey(copied ? "msg.copied" : "table.copyCSV"))
            } icon: {
                Image(systemName: copied ? "checkmark" : "tablecells")
            }
            .labelStyle(.titleAndIcon)
            .typeStyle(.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .probeID("tableCopyCSV")
    }

    private func copyCSV() {
        guard let csv = context?.csv(table: id) else { return }
        pasteboard.clearContents()
        pasteboard.setString(csv, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// fix/t05-u5-part6: the Markdown line of each table row, when the block is exactly one pipe table whose rows the
/// configuration shows one for one (header, separator, body rows). The separator is part of every key (column
/// alignment). nil keys (any other shape: a table inside a list or quote, a table without edge pipes) rebuild as before.
struct TableRowKeys {
    let header: String?
    private let rows: [String]

    init(source: String?, rows count: Int) {
        let lines = (source ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let piped = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
        let separator = lines.count > 1 && lines[1].allSatisfy { "|:- \t".contains($0) } && lines[1].contains("-")
        guard piped, separator, lines.count == count + 2 else {
            header = nil
            rows = []
            return
        }
        header = lines[0] + "\n" + lines[1]
        rows = lines[2...].map { $0 + "\n" + lines[1] }
    }

    func row(_ i: Int) -> String? { rows.indices.contains(i) ? rows[i] : nil }
}

/// A table row (or the header) that is not rebuilt while its key is the same; no key = always rebuilt. Compared through
/// its Equatable conformance, never wrapped in `.equatable()`: an EquatableView hides the GridRow inside from the Grid,
/// which then laid each row's cells out as one stacked cell (goldens 041–070, 091–100).
struct TableRowView<Content: View>: View, Equatable {
    let key: String?
    @ViewBuilder let content: () -> Content

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key != nil && a.key == b.key }

    var body: some View {
        #if DEBUG
        let _ = RendererBodyCounters.tableRows += 1
        #endif
        content()
    }
}
