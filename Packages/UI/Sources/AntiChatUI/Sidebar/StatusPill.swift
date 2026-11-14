// M2.T09 (R-204 AC2; components.md §1 StatusPill): the sidebar footer's download pill — hidden · downloading
// ("Photo 42%", `pill.download`) · paused (`pill.paused`) · error (`pill.error`, click → Settings › Capabilities).
// Fed by `MenuBarProgressModel` (ProgressAggregator → DownloadsLaunch). "Restart to update" (`pill.update`) is M10.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct StatusPill: View {
    enum State: Equatable {
        case hidden
        case downloading(pack: String, percent: Int)
        case paused(pack: String)
        case error(pack: String)
    }

    @Environment(\.openSettings) private var openSettings
    private let fixed: State?
    private let model: MenuBarProgressModel?

    /// `fixed` pins the state (snapshot tests); nil follows the downloads model.
    init(fixed: State? = nil, model: MenuBarProgressModel? = DownloadsLaunch.menuBar) {
        self.fixed = fixed
        self.model = model
    }

    static func state(_ current: PackProgress?) -> State {
        guard let p = current else { return .hidden }
        switch p.state {
        case .downloading, .verifying: return .downloading(pack: p.pack, percent: p.percent)
        case .paused: return .paused(pack: p.pack)
        case .failed: return .error(pack: p.pack)
        case .done: return .hidden
        }
    }

    /// The copy key of a download job's pack name: the onboarding names, "Evil" for the Evil chat variant, and the
    /// background jobs' own names (ModelUpdateService queues "update", Repair "repair"; RC e8fe19986: a failed model
    /// update read "onb.pack.update.name download stopped"). Any other pack id reads "Model", never a raw key.
    /// Shared by the pill, the menu bar item and the download notifications.
    static func packNameKey(_ pack: String) -> String {
        switch pack {
        case "evil": "badge.evil"
        case "update": "pack.update.name"
        case "repair": "pack.repair.name"
        case let p where ModelPack(rawValue: p) != nil: "onb.pack.\(p).name"
        default: "pack.model.name"
        }
    }

    /// The pack's display name (see `packNameKey`).
    static func packName(_ pack: String) -> String { CopyKey(packNameKey(pack)).string() }

    static func title(_ s: State) -> CopyText? {
        switch s {
        case .hidden: nil
        case .downloading(let p, let pct): CopyText(CopyKey("pill.download"), ["pack": packName(p), "percent": "\(pct)"])
        case .paused(let p): CopyText(CopyKey("pill.paused"), ["pack": packName(p)])
        case .error(let p): CopyText(CopyKey("pill.error"), ["pack": packName(p)])
        }
    }

    static func symbol(_ s: State) -> String {
        switch s {
        case .hidden, .downloading: "arrow.down.circle"
        case .paused: "pause.circle"
        case .error: "exclamationmark.circle"
        }
    }

    static func isError(_ s: State) -> Bool { if case .error = s { true } else { false } }

    var body: some View {
        let s = fixed ?? Self.state(model?.current)
        if let title = Self.title(s) {
            Button {
                SettingsNavigator.shared.request(.capabilities)
                openSettings()
            } label: {
                Label { Text(title).typeStyle(.caption) } icon: { Image(systemName: Self.symbol(s)) }
                    .foregroundStyle(Self.isError(s) ? Color.danger : Color.textSecondary)
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.surfaceHover))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.space2)
            .padding(.bottom, Spacing.space1)
            .accessibilityIdentifier("statusPill")
        }
    }
}
