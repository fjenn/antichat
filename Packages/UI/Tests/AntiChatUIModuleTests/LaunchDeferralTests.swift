// M9.T05 (NFR-U1 warm launch): structural checks of the launch path, no timing.
//   - DeferredWorkQueue (AfterFirstFrame): nothing registered before the first usable frame runs before the flush;
//     the flush runs each item once, in order; later items run at once.
//   - The composition root registers the menu bar item and the quick panel with AfterFirstFrame, not in init.
//   - The catalog wiring's initial applies leave the main thread on the launch path.
//   - The first composer focus in a visible window asks for the flush.
//   - MigrationRunner's schema-change check (two in-memory migrations per launch) is a Debug-only default.
import AntiChatStorage
@testable import AntiChatUI
import Foundation
import Testing

@MainActor
@Suite(.isolatedSettings) struct LaunchDeferralTests {
    @Test func queuedWorkWaitsForTheFlushThenRunsOnceInOrder() {
        let q = DeferredWorkQueue()
        var calls: [String] = []
        q.run("menuBar") { calls.append("menuBar") }
        q.run("quickPanel") { calls.append("quickPanel") }
        #expect(calls.isEmpty, "no deferred work before the first usable frame")
        #expect(q.pendingLabels == ["menuBar", "quickPanel"])
        q.flush()
        #expect(calls == ["menuBar", "quickPanel"])
        q.flush()  // the fallback after the composer's flush: idempotent
        #expect(calls == ["menuBar", "quickPanel"], "each item runs once")
        q.run("late") { calls.append("late") }
        #expect(calls.last == "late", "after the flush, work runs at once")
        #expect(q.ran == ["menuBar", "quickPanel", "late"])
        #expect(q.pendingLabels.isEmpty)
    }

    /// Source checks of the composition root (the app target has no unit-test host).
    static func source(_ relative: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func menuBarAndQuickPanelStartAfterTheFirstFrame() throws {
        let app = try Self.source("App/AntiChat/AntiChatApp.swift")
        #expect(app.contains("AfterFirstFrame.run(\"menuBar\") { MenuBarController.shared.start() }"))
        #expect(app.contains("AfterFirstFrame.run(\"quickPanel\") { QuickPanelController.shared.install("))
        let direct = app.split(separator: "\n").filter {
            let l = $0.trimmingCharacters(in: .whitespaces)
            return l.hasPrefix("MenuBarController.shared.start()") || l.hasPrefix("QuickPanelController.shared.install(")
        }
        #expect(direct.isEmpty, "started synchronously in init: \(direct)")
        let delegate = try Self.source("App/AntiChat/AppDelegate.swift")
        #expect(delegate.contains("AfterFirstFrame.armFallback("), "a launch without a focused composer still starts them")
        let composer = try Self.source("Packages/UI/Sources/AntiChatUI/Composer/ComposerTextView.swift")
        #expect(composer.contains("Signposts.markLaunchToUsable()\n            AfterFirstFrame.usableFrameReached()"))
    }

    @Test func launchCatalogWiringAppliesOffTheMainThread() throws {
        let boot = try Self.source("Packages/UI/Sources/AntiChatUI/AppBootstrap.swift")
        #expect(boot.contains("wireSearchEngines(store: store, registry: .shared, initialOffMain: true)"))
        #expect(boot.contains("wireCuratedConnections(store: store, curated: .shared, initialOffMain: true)"))
        #expect(boot.contains("Task.detached(priority: .utility) { protectDataAtRest(database: database) }"))
    }

    @Test func schemaChangeEraseIsADebugOnlyDefault() {
        #if DEBUG
        #expect(MigrationRunner.erasesOnSchemaChangeByDefault)
        #else
        // Release and the optimized perf-harness build (ANTICHAT_PERF_HARNESS) open an up-to-date file without
        // migrating two in-memory databases.
        #expect(!MigrationRunner.erasesOnSchemaChangeByDefault)
        #endif
        #expect(MigrationRunner().eraseOnSchemaChange == MigrationRunner.erasesOnSchemaChangeByDefault)
    }
}
