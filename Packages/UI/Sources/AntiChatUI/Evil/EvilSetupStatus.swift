// Owner bug 2026-11-16: with Evil Mode on, the composer let you pick Evil and type, and only Send said "Chat Evil not
// available on this Mac yet" — while the 85 GB model was downloading, or sat verified in the store without its install
// view. EvilSetupStatus is what the composer and the mode picker say instead, from the live facts Settings ›
// Capabilities shows for the Evil chat model (PackManagementModel.evilChatState): how far the download is, that the
// setup is being finished, or that it did not finish (with Retry). nil = Evil is ready (or not on this Mac at all).
import AntiChatDesign
import AntiChatPlatform
import Foundation
import SwiftUI

public struct EvilSetupStatus: Equatable, Sendable {
    public var line: CopyText
    /// The state does not move by itself: Retry (the install reconcile, failed downloads requeued) is offered.
    public var canRetry: Bool
    /// Bytes are still arriving: the composer keeps the pack facts fresh so the percentage moves.
    public var isMoving: Bool

    public init?(_ state: PackRowState?) {
        switch state {
        case .downloading(let pct0, let paused, let done, let total):
            let pct = total > 0 ? PackRow.percent(done: done, total: total) : pct0
            line = CopyText(CopyKey(paused ? "evil.setup.paused" : "evil.setup.downloading"), ["percent": String(pct)])
            canRetry = false
            isMoving = !paused
        case .checking:
            line = CopyText(CopyKey("evil.setup.finishing"))
            canRetry = false
            isMoving = true
        case .notDownloaded(_, true):
            line = CopyText(CopyKey("evil.setup.waiting"))
            canRetry = false
            isMoving = true
        case .notDownloaded(_, false):
            line = CopyText(CopyKey("evil.setup.notDownloaded"))
            canRetry = true
            isMoving = false
        case .failed:
            line = CopyText(CopyKey("evil.setup.failed"))
            canRetry = true
            isMoving = false
        default:
            return nil
        }
    }
}

/// The line under the field while the shown chat is an Evil one and Evil cannot answer yet — said before a word is
/// typed, with Retry when nothing will change by itself.
struct EvilSetupNotice: View {
    let text: CopyText
    var retry: (@MainActor () -> Void)?

    var body: some View {
        HStack(spacing: Spacing.space2) {
            ComposerNotice(text: text)
            if let retry {
                Button { retry() } label: { Text(CopyKey("set.cap.retry")) }
                    .controlSize(.small)
                    .probeID("evil.setup.retry")
                    .padding(.trailing, Spacing.space3)
            }
        }
        .accessibilityElement(children: .contain)
        .probeID("evil.setup.notice")
    }
}
