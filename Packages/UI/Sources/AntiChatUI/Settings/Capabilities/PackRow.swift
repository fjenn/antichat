// M2.T21 step 1 (S-21 PackRow; components.md): one pack in Settings › Capabilities — icon, name, the state line
// (Off · Downloads {size} / n % with Pause–Resume and Cancel / Checking / Ready · {size} on disk / Update available /
// Not available on this Mac · {reason} / Didn't finish + Retry) and the on/off switch (Chat is always on). Which
// modes a pack covers is under Advanced. Turning a pack off opens DisablePackSheet.
// The fifth row is Evil Mode (`pack == nil`, owner 2026-11-16): the same icon, name, state line and switch; its
// switch runs the 18+ sheet and queues the Evil variants (CapabilitiesSection), and it has no Pause / Cancel.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct PackRow: View {
    /// nil = the Evil Mode row.
    let pack: ModelPack?
    let state: PackRowState
    let isOn: Bool
    var diskShortGB: Int?
    /// Why the last Enable was refused (catalog), M2 review #14.
    var refusal: CopyText?
    var onToggle: (Bool) -> Void = { _ in }
    var onPause: (Bool) -> Void = { _ in }
    var onRetry: () -> Void = {}

    /// "chat" … "video", or "evil": the row's ids.
    private var key: String { pack?.rawValue ?? "evil" }
    private var name: CopyKey { pack.map { CopyKey("onb.pack.\($0.rawValue).name") } ?? CopyKey("mode.evil") }

    private var available: Bool {
        switch state {
        case .notAvailable, .comingSoon: false
        default: true
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            PackIllustration(pack: pack, size: 32)
                .opacity(available ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .typeStyle(.body)
                    .foregroundStyle(available ? Color.textPrimary : Color.textSecondary)
                stateLine
                if let gb = diskShortGB {
                    Text(CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)]))
                        .typeStyle(.caption).foregroundStyle(Color.warning)
                }
                if let refusal {
                    Text(refusal).typeStyle(.caption).foregroundStyle(Color.warning)
                        .probeID("settings.pack.\(key).refusal")
                }
            }
            Spacer(minLength: Spacing.space3)
            controls
            if pack == .chat {
                // VQ (S-21 Capabilities): Chat cannot be turned off — say so instead of a dimmed switch with no reason.
                Text(CopyKey("set.cap.alwaysOn"))
                    .typeStyle(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .help(CopyKey("set.cap.chat.locked").string())
                    .probeID("settings.pack.chat.toggle")
            } else {
                // Hidden label: the switch's name for VoiceOver (the audit's "Element may need a title", M9.T03).
                Toggle(isOn: Binding(get: { isOn }, set: onToggle)) { Text(name) }
                    .toggleStyle(.accessibleSwitch)
                    .labelsHidden()
                    .disabled(!available || (!isOn && diskShortGB != nil))  // r66 F5: no Enable the disk rule refuses
                    .probeID(pack == nil ? "settings.evil.enabled" : "settings.pack.\(key).toggle")
            }
        }
        .padding(.vertical, Spacing.space1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(name))  // a named group (M9.T03)
        .probeID("settings.pack.\(key)")
    }

    /// r66 F5: the bytes done, never rounded up ("0.1 GB" for 5 MB beside "0 %"): MB under 1 GB, else GB to 0.1 down.
    static func doneSize(_ bytes: Int64) -> String {
        let b = max(0, bytes)
        if b < 1_000_000_000 { return "\(b / 1_000_000) MB" }
        return String(format: "%.1f GB", (Double(b) / 1e8).rounded(.down) / 10)
    }

    /// Whole percent of `done` / `total`, rounded down (99 at most until the pack is ready), so it agrees with the bytes.
    static func percent(done: Int64, total: Int64) -> Int {
        guard total > 0 else { return 0 }
        return min(99, max(0, Int((Double(done) / Double(total) * 100).rounded(.down))))
    }

    @ViewBuilder private var stateLine: some View {
        Group {
            switch state {
            case .off where pack == .chat:
                Text(CopyKey("set.cap.chat.value"))  // Chat is always on
            case .off(let bytes):
                Text(bytes > 0 ? CopyText(CopyKey("set.cap.download"), ["size": OnboardingModel.size(bytes)]) : CopyText(CopyKey("set.cap.state.off")))
            case .notDownloaded(let bytes, let queued):
                // VQ: truthful — nothing has arrived yet, so no bar and no "0 %".
                Text(CopyText(CopyKey(queued ? "set.cap.state.queued" : "set.cap.state.notDownloaded"),
                              ["size": OnboardingModel.size(bytes)]))
            case .downloading(let pct0, let paused, let done, let total):
                let pct = total > 0 ? Self.percent(done: done, total: total) : pct0
                // The words, then a slim bar under them.
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Group {
                        if total > 0 {
                            Text(CopyText(CopyKey(paused ? "set.cap.state.pausedBytes" : "set.cap.state.downloadingBytes"),
                                          ["done": Self.doneSize(done), "total": OnboardingModel.size(total), "percent": String(pct)]))
                        } else {
                            Text(paused ? CopyText(CopyKey("onb.4.row.paused")) : CopyText(CopyKey("onb.4.row.downloading"), ["percent": String(pct)]))
                        }
                    }
                    .monospacedDigit()
                    ProgressView(value: Double(pct), total: 100).progressViewStyle(.linear).controlSize(.small)
                        .frame(maxWidth: 240)
                        .accessibilityLabel(Text(name))
                }
            case .checking: Text(CopyKey("onb.4.row.checking"))
            case .ready(let bytes): Text(CopyText(CopyKey("set.cap.state.ready"), ["size": OnboardingModel.size(bytes)]))
            case .updateAvailable: Text(CopyKey("set.cap.state.update")).foregroundStyle(Color.accentColor)
            case .notAvailable(let reason): Text(CopyText(CopyKey("set.cap.notAvailable"), ["reason": reason.string]))
            case .failed: Text(CopyKey("set.cap.state.failed")).foregroundStyle(Color.danger)
            case .comingSoon: Text(CopyKey("set.cap.comingSoon"))
            }
        }
        .typeStyle(.caption)
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .probeID("settings.pack.\(key).state")
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .notDownloaded(_, false):
            // Enable again (disk rule + queue); Chat, always on, retries the setup queue.
            Button { if pack == .chat { onRetry() } else { onToggle(true) } } label: { Text(CopyKey("set.cap.downloadNow")) }
                .controlSize(.small)
                .disabled(diskShortGB != nil)  // r66 F5: the warning above says why
                .probeID("settings.pack.\(key).download")
        case .downloading(_, let paused, _, _) where pack != nil:
            // Small and quiet: the bar is the news, these are there when wanted.
            Button { onPause(!paused) } label: { Text(CopyKey(paused ? "set.cap.resume" : "set.cap.pause")) }
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Color.textSecondary)
            Button { onToggle(false) } label: { Text(CopyKey("set.cap.cancel")) }
                .accessibilityIdentifier("set.cap.cancel")
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(Color.textSecondary)
        case .failed:
            Button(action: onRetry) { Text(CopyKey("set.cap.retry")) }.controlSize(.small)
        default: EmptyView()
        }
    }
}

/// Step 2: "Turn off {pack}?" — Turn off (files stay) / Turn off and delete ({size}, SpaceAccountant's exact value).
/// Only shown when the pack has something on disk (CapabilitiesSection turns an empty pack off directly).
struct DisablePackSheet: View {
    let pack: ModelPack
    let frees: Int64
    let onKeep: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyText(CopyKey("caps.disable.title"), ["pack": CopyKey("onb.pack.\(pack.rawValue).name").string()]))
                .typeStyle(.title3)
                .foregroundStyle(Color.textPrimary)
            Text(CopyKey("caps.disable.body"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(action: onCancel) { Text(CopyKey("set.cap.cancel")) }
                    .accessibilityIdentifier("set.cap.cancel")
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onKeep) { Text(CopyKey("caps.disable.keep")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("caps.disable.keep")
                if frees > 0 {
                    Button(role: .destructive, action: onRemove) {
                        Text(CopyText(CopyKey("caps.disable.remove"), ["size": OnboardingModel.size(frees)]))
                    }
                    .probeID("caps.disable.remove")
                }
            }
        }
        .padding(Spacing.space5)
        .frame(width: 440)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("caps.disable.sheet")
    }
}
