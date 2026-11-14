// Model info (M1.T25 step 2, R-234 AC2; T25b UI leg of AT-234; components.md §3 ActionBar ⋯ "Model info"). With
// Settings → Capabilities → Advanced "Show model info" on (`Defaults.Keys.showModelInfo`, default off), the reply's ⋯
// menu shows `msg.modelInfo`, which opens this popover: model id, model sha (short; the full hash on hover and as
// selectable text), mode, sampling and tok/s, read from the stored row (`message.model_id` + `provenance_json`,
// written by M1.T25a's ProvenanceRecorder), so the popover shows exactly what the database holds. Off: the item is
// absent (the default UI shows no model names, R-007). Local only: no network on this path.
import AntiChatDesign
import AntiChatFoundation
import AntiChatStorage
import SwiftUI

/// What the Model info popover lists for one assistant message.
public struct ModelInfo: Equatable, Sendable {
    public var modelID: String?
    public var modelSHA: String?
    public var mode: ChatMode?
    /// `provenance_json.sampling_json`, in display order (`samplingOrder` first, the rest by name).
    public var sampling: [(name: String, value: Double)]
    public var tokPerS: Double?
    /// True when tok/s is the app's estimate (`tok_per_s_source = app-estimate`: interrupted before a `usage`).
    public var tokPerSEstimated: Bool

    public init(modelID: String?, provenance: MessageProvenance?) {
        self.modelID = modelID
        modelSHA = provenance?.modelSHA
        mode = provenance?.mode
        sampling = Self.ordered(provenance?.sampling ?? [:])
        tokPerS = provenance?.tokPerS
        tokPerSEstimated = provenance?.tokPerSSource == "app-estimate"
    }

    /// The stored row of `messageID` (nil: no such message, or not an assistant reply).
    public static func load(_ messageID: String, database: AppDatabase) -> ModelInfo? {
        do {
            guard let m = try database.read({ try MessageRecord.fetchOne($0, key: messageID) }), m.role == .assistant
            else { return nil }
            return ModelInfo(modelID: m.modelID, provenance: m.provenance)
        } catch {
            AppLog.log(.ui, .error, "model info read failed: \(error)")
            return nil
        }
    }

    public static func == (a: ModelInfo, b: ModelInfo) -> Bool {
        a.modelID == b.modelID && a.modelSHA == b.modelSHA && a.mode == b.mode && a.tokPerS == b.tokPerS
            && a.tokPerSEstimated == b.tokPerSEstimated
            && a.sampling.map(\.name) == b.sampling.map(\.name) && a.sampling.map(\.value) == b.sampling.map(\.value)
    }

    // MARK: Display (pure; ModelInfoTests)

    /// ProvenanceRecorder's `sampling_json` keys in the order a person reads them.
    static let samplingOrder = ["temperature", "top_p", "top_k", "min_p", "max_tokens", "seed", "reasoning", "reasoning_budget"]

    static func ordered(_ sampling: [String: Double]) -> [(name: String, value: Double)] {
        sampling.sorted { a, b in
            let ia = samplingOrder.firstIndex(of: a.key) ?? samplingOrder.count
            let ib = samplingOrder.firstIndex(of: b.key) ?? samplingOrder.count
            return ia != ib ? ia < ib : a.key < b.key
        }.map { (name: $0.key, value: $0.value) }
    }

    /// The sha's first 12 hex characters (git-style short hash).
    public var shortSHA: String? { modelSHA.map { String($0.prefix(12)) } }

    /// "temperature 0.7 · top_p 0.8 · top_k 20 · max_tokens 4096" (integers without a fraction; a no-break space inside
    /// each pair, so a line wraps only between pairs).
    public var samplingLine: String? {
        sampling.isEmpty ? nil : sampling.map { "\($0.name)\u{00A0}\(Self.number($0.value))" }.joined(separator: " · ")
    }

    /// tok/s with one decimal ("41.3").
    public var tokPerSText: String? { tokPerS.map { String(format: "%.1f", $0) } }

    static func number(_ v: Double) -> String {
        if v.rounded() == v, abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// The popover the reply's ⋯ → Model info opens.
public struct ModelInfoPopover: View {
    let info: ModelInfo

    public init(info: ModelInfo) { self.info = info }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("msg.modelInfo"))
                .typeStyle(.headline)
                .foregroundStyle(Color.textPrimary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space1) {
                row(CopyKey("msg.modelInfo.model"), info.modelID, id: "modelInfo.model")
                row(CopyKey("msg.modelInfo.sha"), info.shortSHA, id: "modelInfo.sha", full: info.modelSHA)
                row(CopyKey("msg.modelInfo.mode"), info.modeText?.string, id: "modelInfo.mode")
                row(CopyKey("msg.modelInfo.sampling"), info.samplingLine, id: "modelInfo.sampling")
                row(CopyKey("msg.modelInfo.speed"), info.speedText?.string, id: "modelInfo.speed")
            }
        }
        .padding(Spacing.space3)
        .frame(width: 320, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelInfoPopover")
    }

    /// One label / value row; a missing value shows "—". `full` (the whole sha) is the value's hover help.
    private func row(_ label: CopyKey, _ value: String?, id: String, full: String? = nil) -> some View {
        GridRow {
            Text(label)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textSecondary)
                .gridColumnAlignment(.leading)
            Text(verbatim: value ?? "—")
                .typeStyle(.footnote)
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help(Text(verbatim: full ?? value ?? ""))
                .accessibilityIdentifier(id)
        }
    }
}

extension ModelInfo {
    /// `mode.normal` / `mode.evil`.
    var modeText: CopyText? { mode.map { CopyText($0 == .evil ? CopyKey("mode.evil") : CopyKey("mode.normal")) } }

    /// "41.3 tok/s", or "41.3 tok/s (estimated)" for the app's estimate.
    var speedText: CopyText? {
        tokPerSText.map {
            CopyText(tokPerSEstimated ? CopyKey("msg.modelInfo.tokPerSEstimated") : CopyKey("msg.modelInfo.tokPerS"),
                     ["rate": $0])
        }
    }
}
