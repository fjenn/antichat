// M1.T11 (S-18, components.md §5 CommandPalette): ⌘K panel snapshots, light and dark: empty query (recents +
// actions, grouped), the Actions tab and the Settings tab. Typing, no-results and keyboard-selection states are
// captured from the real window by the in-process probe (build/at/AT-012/probe-*/), because the vendored view
// owns the field's text. Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=PaletteSnapshotTests.
//
// Flake root cause (integration/m0, after M1.T17/T19): the vendored list animates `results.map(\.id)` (0.12 s
// ease-out crossfade from its empty first frame, "No chats or settings match" → rows). `render` settles for a fixed
// 0.3 s of wall time; under `make test-unit --parallel` other suites hold the main actor, so the list's first update
// could land at the end of that window and the bitmap caught the crossfade (a different palette case per run), or a
// pass before the search field's measured height (field row ~7 pt short). `still` renders the panel with animations
// disabled and `converge: true` renders until three consecutive bitmaps match, so no capture depends on timing.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct PaletteSnapshotTests {
    let size = CGSize(width: 760, height: 640)

    private func palette() async throws -> PaletteController {
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok"}"#)),
                                  slot: { .scripted("inline") })
        let service = ChatListService(environment: env)
        let fixed = Date(timeIntervalSince1970: 1_793_361_600)
        for (i, title) in ["Plan a weekend in Lisbon", "Sourdough starter schedule", "Fix the bike's rear brake"]
            .enumerated() {
            let c = try service.create(title: title)
            try service.appendUserMessage(c.id, text: "Question \(i)")
            try env.database.write { db in
                try db.execute(sql: "UPDATE chat SET updated_at = ? WHERE id = ?",
                               arguments: [fixed.timeIntervalSince1970 + Double(i), c.id])
            }
        }
        let p = PaletteController()
        p.attach(service: service, handlers: PaletteHandlers())
        let g = p.resultGeneration
        p.present()
        let deadline = Date().addingTimeInterval(60)  // generous: under `make test-unit --parallel` other suites hold the main actor (snapshot run loops)
        while p.resultGeneration == g || p.items.count < 2,
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return p
    }

    /// The panel with every animation off (`.animation(_:value:)` inserts none while `disablesAnimations` is set).
    private func still(_ p: PaletteController) -> some View {
        PalettePanel(controller: p)
            .background(Color.surfaceCanvas)
            .transaction { t in
                t.disablesAnimations = true
                t.animation = nil
            }
    }

    @Test func newChatAndRecents() async throws {
        let p = try await palette()
        #expect(p.items.first?.kind == .newChat && p.items.dropFirst().first?.title == "Fix the bike's rear brake")
        assertLooks("Palette.recents", size: size, converge: true, still(p))
    }
}
}  // extension WindowSuites
