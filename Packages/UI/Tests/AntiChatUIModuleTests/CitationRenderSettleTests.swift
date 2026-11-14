// AT-248 c1 (M7 at248): a finished web reply's pills render in the real reply view, first in the checking state and,
// once `.citationsSettled` lands (citationsChecking false, maybe a removed marker), as settled pills — one pill view per
// marker (a repeated `[2]` is two pills, a combined `[1,2]` one pill naming two sources); a marker for an unfetched
// source never becomes a pill. Hosted in an ordered-in offscreen window (RendererRig), counted from the probe anchors.
//   make test-unit FILTER=CitationRenderSettleTests
import AntiChatHarness
import AntiChatStorage
import AppKit
import Observation
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct CitationRenderSettleTests {
    @MainActor @Observable final class Box {
        var message: ConversationModel.Message
        init(_ m: ConversationModel.Message) { message = m }
    }

    struct Reply: View {
        let box: Box
        var body: some View {
            AssistantMessageView(message: box.message, status: StatusLineModel(phase: .idle, hasContent: true, modelLoading: false),
                                 onEditPrompt: {}, onRetry: {})
        }
    }

    static func source(_ n: Int, fetched: Bool = true) -> MessageProvenance.WebSourceRecord {
        .init(n: n, url: "https://s\(n).example/p", title: "Title \(n)", site: "s\(n).example", date: nil, faviconData: nil,
              snippet: "s", fetched: fetched)
    }

    /// (settled pill ids with one entry per drawn pill, checking pills drawn).
    static func pills(_ rig: RendererRig.Host) -> (settled: [String], checking: Int) {
        var settled: [String] = [], checking = 0
        for id in UIProbeRegistry.ids(prefix: "citation.", in: rig.window) {
            let n = rig.frames(id).count
            if id.hasSuffix(".checking") { checking += n } else { settled += Array(repeating: id, count: n) }
        }
        return (settled.sorted(), checking)
    }

    @Test func pillsRenderCheckingThenSettledAfterTheVerdict() async throws {
        _ = NSApplication.shared
        let text = "macOS 27 is the current release [1,2]. Version 27.2 shipped in October [2]. It needs Apple silicon [2]. "
            + "Its codename is Golden Gate [4]. Old Macs lost support [3]."
        var m = ConversationModel.Message(id: "a1", role: .assistant, text: text, status: .done)
        m.sources = [Self.source(1), Self.source(2), Self.source(3), Self.source(4, fetched: false)]
        m.citationsChecking = true
        let box = Box(m)
        let rig = RendererRig.Host(Reply(box: box), look: .light)
        await rig.settle(min: 0.5, stableFor: 0.4, max: 6, minHeight: 40)
        var drawn = Self.pills(rig)
        #expect(drawn.checking == 4 && drawn.settled.isEmpty, "while checking: \(drawn)")
        // The verdict: the verifier removed the `[3]` marker; the rest stands.
        box.message.text = text.replacingOccurrences(of: " [3]", with: "")
        box.message.citationsChecking = false
        await rig.settle(min: 0.5, stableFor: 0.4, max: 6, minHeight: 40)
        for _ in 0..<100 where Self.pills(rig).checking > 0 {  // MarkdownView re-parses off-main: up to 5 s more
            try? await Task.sleep(for: .milliseconds(50)); rig.layout()
        }
        drawn = Self.pills(rig)
        #expect(drawn.checking == 0, "checking pills left after the verdict: \(drawn)")
        #expect(drawn.settled == ["citation.1,2", "citation.2", "citation.2"], "settled pills: \(drawn)")
    }
}
}  // extension WindowSuites
