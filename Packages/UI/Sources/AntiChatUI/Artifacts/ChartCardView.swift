// M6.T12 step 4 (R-274 AC2; components.md ChartCard; S-15): the chart inline (the rendered PNG@2x), hover actions
// Save PNG / Save SVG / Copy (PNG to the pasteboard) / View data (ChartDataTable: the exact injected rows). The data
// comes from the chart's snapshot (`<sha>.chart.json` beside the PNG, the same JSON as `artifact_version.spec_json`),
// so a reloaded chat or a freed DuckDB still shows it. Spec error state: `chart.specError` + the data table.
// A click on the chart opens it in the window side panel when there is one (onOpenInPanel, M6.T13).
import AntiChatDesign
import AntiChatTools
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pasteboard / save side of the chart actions, injectable for tests.
@MainActor
public protocol ChartActionPerforming: AnyObject {
    func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL?
    func copyImage(_ png: Data)
}

@MainActor
public final class WorkspaceChartActions: ChartActionPerforming {
    public static let shared = WorkspaceChartActions()
    public init() {}

    public func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL? {
        await WorkspaceFileActions.shared.chooseSaveDestination(suggestedName: suggestedName, contentType: contentType)
    }

    public func copyImage(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }
}

@MainActor
@Observable
public final class ChartCardModel {
    public enum State: Equatable { case rendering, ready, specError(String) }
    public let title: String
    public let pngURL: URL?
    public let state: State
    public let snapshot: ChartSnapshot?
    /// Columns + rows for View data (the snapshot's, or the data_ref's for a spec error).
    public let columns: [String]
    public let rows: [[String?]]
    public var showsData = false
    public private(set) var lastError: String?
    @ObservationIgnored private let actions: ChartActionPerforming

    public init(title: String, pngURL: URL?, state: State, snapshot: ChartSnapshot? = nil, fallback: DataRef? = nil,
                actions: ChartActionPerforming? = nil) {
        self.title = title
        self.pngURL = pngURL
        self.state = state
        self.snapshot = snapshot ?? pngURL.flatMap(ChartSnapshot.load(png:))
        columns = self.snapshot?.columns.nilIfEmpty ?? fallback?.columns ?? []
        rows = self.snapshot.flatMap { $0.columns.isEmpty ? nil : $0.rows } ?? fallback?.rows ?? []
        self.actions = actions ?? WorkspaceChartActions.shared
        if case .specError = state { showsData = !columns.isEmpty }
    }

    public var isReady: Bool { state == .ready }
    public var baseName: String { FileOutNames.filename(title: title, ext: "png").dropLast(4).description }
    public var png: Data? { pngURL.flatMap { try? Data(contentsOf: $0) } }

    @discardableResult
    public func savePNG() async -> URL? {
        guard isReady, let png else { return nil }
        return await save(png, name: baseName + ".png", type: .png)
    }

    @discardableResult
    public func saveSVG() async -> URL? {
        guard isReady, let svg = snapshot?.svg else { return nil }
        return await save(Data(svg.utf8), name: baseName + ".svg", type: .svg)
    }

    public func copy() {
        guard isReady, let png else { return }
        actions.copyImage(png)
    }

    private func save(_ data: Data, name: String, type: UTType) async -> URL? {
        guard let url = await actions.chooseSaveDestination(suggestedName: name, contentType: type) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            lastError = nil
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}

private extension Array { var nilIfEmpty: Self? { isEmpty ? nil : self } }

public struct ChartCardView: View {
    @Bindable var model: ChartCardModel
    /// M6.T13: a click on the chart opens it in the window's side panel.
    let onOpenInPanel: (() -> Void)?
    @State private var hovering = false

    public static let width: CGFloat = 520

    public init(model: ChartCardModel, onOpenInPanel: (() -> Void)? = nil) {
        self.model = model
        self.onOpenInPanel = onOpenInPanel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ZStack(alignment: .topTrailing) {
                chart
                if hovering, model.isReady { actions.padding(Spacing.space2) }
            }
            if model.showsData, !model.columns.isEmpty {
                ChartDataTable(columns: model.columns, rows: model.rows)
                    .frame(maxHeight: 240)
            }
        }
        .padding(Spacing.space2)
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width, alignment: .leading)  // VQ-M10 S-15: shrinks with the column beside the side panel
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(isError ? Color.danger : Color.borderSubtle, lineWidth: Stroke.control)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chartCard")
        .accessibilityLabel(Text(verbatim: model.title))
    }

    /// The chart's width in points: the PNG's pixel width over the renderer's scale (2).
    static func naturalWidth(_ image: NSImage) -> CGFloat {
        let px = image.representations.map(\.pixelsWide).max() ?? 0
        return px > 0 ? CGFloat(px) / 2 : image.size.width
    }

    private var isError: Bool { if case .specError = model.state { true } else { false } }

    @ViewBuilder private var chart: some View {
        switch model.state {
        case .rendering:
            ZStack {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken)
                ProgressView().controlSize(.small)
            }
            .frame(height: 180)
        case .specError:
            HStack(spacing: Spacing.space2) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.danger)
                Text(CopyKey("chart.specError")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
            }
            .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
            .accessibilityIdentifier("chartSpecError")
        case .ready:
            if let png = model.png, let image = NSImage(data: png) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    // Never larger than the chart's own size (VegaRenderer draws at 2×): a small Vega-Lite chart
                    // (few bars, default step width) was stretched to the card width, blurred and oversized (M6.T21
                    // visual QA, s15-cards-panel).
                    .frame(maxWidth: Self.naturalWidth(image), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .accessibilityLabel(Text(verbatim: model.title))
                    .accessibilityIdentifier("chartImage")
                    .onDrag { NSItemProvider(contentsOf: model.pngURL) ?? NSItemProvider() }
                    .onTapGesture { onOpenInPanel?() }
                    .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space opens it in the panel too
                    .accessibilityAction { onOpenInPanel?() }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.space1) {
            Button { Task { await model.savePNG() } } label: { Text(CopyKey("chart.savePNG")) }
                .accessibilityIdentifier("chartSavePNG")
            Button { Task { await model.saveSVG() } } label: { Text(CopyKey("chart.saveSVG")) }
                .accessibilityIdentifier("chartSaveSVG")
                .disabled(model.snapshot?.svg == nil)
            Button { model.copy() } label: { Text(CopyKey("chart.copy")) }
                .accessibilityIdentifier("chartCopy")
            Button {
                withAnimation(.easeOut(duration: 0.15)) { model.showsData.toggle() }
            } label: { Text(CopyKey("chart.viewData")) }
                .accessibilityIdentifier("chartViewData")
                .disabled(model.columns.isEmpty)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }
}

/// The exact rows the chart was drawn from (View data), monospaced numbers, scrollable.
public struct ChartDataTable: View {
    let columns: [String]
    let rows: [[String?]]
    public static let maxRows = 1_000

    public init(columns: [String], rows: [[String?]]) {
        self.columns = columns
        self.rows = rows
    }

    public var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Grid(alignment: .leading, horizontalSpacing: Spacing.space3, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                        Text(verbatim: c).typeStyle(.caption).fontWeight(.semibold).foregroundStyle(Color.textPrimary)
                    }
                }
                Divider()
                ForEach(Array(rows.prefix(Self.maxRows).enumerated()), id: \.offset) { _, r in
                    GridRow {
                        ForEach(0..<columns.count, id: \.self) { i in
                            Text(verbatim: i < r.count ? (r[i] ?? "—") : "")
                                .typeStyle(.caption).monospacedDigit().foregroundStyle(Color.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(Spacing.space2)
        }
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken))
        .accessibilityIdentifier("chartDataTable")
    }
}
