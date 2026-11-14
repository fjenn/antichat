// fix/selection-hang: a WindowGroup-style parent that re-evaluates its content must not rebuild the window's model
// objects. The old host (`State(initialValue: ChatSessions(…))`) built one per re-evaluation — the stuck app had
// thousands, each with its NotificationCenter registrations; `WindowOwner` behind `@StateObject` builds one per window.
//   make test-unit FILTER=WindowOwnerTests
import AntiChatHarness
import AntiChatStorage
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct WindowOwnerTests {
    @MainActor final class Counter { var made = 0 }
    @MainActor @Observable final class Ticker { var n = 0 }

    final class Made { let id: Int; init(_ id: Int) { self.id = id } }

    /// The old pattern: a new object per parent re-evaluation (State keeps the first, the rest were still built).
    struct StateHost: View {
        @State private var made: Made
        init(counter: Counter) {
            counter.made += 1
            _made = State(initialValue: Made(counter.made))
        }
        var body: some View { Text(verbatim: "\(made.id)") }
    }

    /// The fix: the autoclosure runs once per view identity.
    struct OwnerHost: View {
        @StateObject private var owner: WindowOwner<Made>
        init(counter: Counter) {
            _owner = StateObject(wrappedValue: WindowOwner { counter.made += 1; return Made(counter.made) })
        }
        var body: some View { Text(verbatim: "\(owner.objects.id)") }
    }

    struct Parent<Child: View>: View {
        let ticker: Ticker
        @ViewBuilder let child: () -> Child
        var body: some View {
            VStack {
                Text(verbatim: "tick \(ticker.n)")  // read here: every tick re-evaluates this body and the child's init
                child()
            }
        }
    }

    private func run<Child: View>(_ child: @escaping () -> Child, ticks: Int) -> Ticker {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let ticker = Ticker()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Parent(ticker: ticker, child: child))
        BackgroundRun.present(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for _ in 0..<ticks {
            ticker.n += 1
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        window.contentView = nil
        window.close()
        return ticker
    }

    @Test func reEvaluationCreatesNothing() {
        let old = Counter()
        _ = run({ StateHost(counter: old) }, ticks: 20)
        #expect(old.made > 10, "the old State(initialValue:) host was rebuilt per re-evaluation (\(old.made))")
        let fixed = Counter()
        _ = run({ OwnerHost(counter: fixed) }, ticks: 20)
        #expect(fixed.made == 1, "WindowOwner built \(fixed.made) objects for one window")
        print("WindowOwnerTests: 20 re-evaluations: State(initialValue:) host built \(old.made), WindowOwner built \(fixed.made)")
    }

    /// A dropped ChatSessions / WindowState is released (and unregisters its observers in `deinit`).
    @Test func droppedWindowObjectsAreReleased() throws {
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: InProcessScriptedEngine(script: try EngineScript(text: "")),
                                  slot: { .scripted("inline") })
        weak var sessions: ChatSessions?
        weak var state: WindowState?
        do {
            let s = ChatSessions(environment: env)
            let w = WindowState(service: ChatListService(environment: env), seed: 1)
            sessions = s
            state = w
        }
        #expect(sessions == nil && state == nil)
        // Posting what they observed reaches nothing (no crash, no zombie handler).
        NotificationCenter.default.post(name: SkillTools.didChange, object: nil)
    }
}
}
