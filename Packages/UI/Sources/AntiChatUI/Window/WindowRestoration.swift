// Multiple windows and their restoration (M1.T24 step 6; R-104 AC2). Each main window is a
// `WindowGroup(id: "main", for: MainWindowValue.self)` instance: its value is the chat it shows (kept in sync here,
// so macOS state restoration reopens the same chat), `.incognito` asks for a fresh incognito chat (⇧⌘N; consumed
// on appear, never restored — the window is not restorable while incognito, M1.T20). The sidebar state is
// `SceneStorage`; the frame is the window's own restorable frame.
// M10.T09 (AT-FA-10, R-208 AC2): the shown chat is also written to the app's own store (`LastShownChatStore`, keyed
// by the window's SceneStorage `windowKey`), and after a kill or crash each window takes that chat back, whether or
// not macOS saved its restorable state before the process died.
import AntiChatHarness
import AppKit
import SwiftUI

private struct WindowRestoration: ViewModifier {
    let state: WindowState
    @Binding var value: MainWindowValue?
    @SceneStorage("sidebarCollapsed") private var sidebarCollapsed = false
    /// The window's own key in `LastShownChatStore` (restored with the window when macOS restores it).
    @SceneStorage("windowKey") private var windowKey = ""
    @State private var applied = false
    @Environment(\.openWindow) private var openWindow

    private var store: LastShownChatStore { .shared }

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !applied else { return record() }
                applied = true
                // After the window's onReady wiring (incognito factory, sessions) has run.
                Task { @MainActor in apply() }
            }
            .onChange(of: state.currentChatID) { _, id in
                guard state.route != .incognito else { return }
                value = id.map(MainWindowValue.chat)
                record()
            }
            .onChange(of: state.columnVisibility) { _, v in sidebarCollapsed = v == .detailOnly }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard let w = note.object as? NSWindow, w === state.window, !windowKey.isEmpty else { return }
                store.activated(key: windowKey, incognito: state.isIncognito)
            }
            .onDisappear { if !windowKey.isEmpty { store.closed(key: windowKey) } }
    }

    private func apply() {
        let restoredKey = windowKey.isEmpty ? nil : windowKey
        if windowKey.isEmpty { windowKey = UUID().uuidString }
        // After a kill or crash: the chat this window (or, for a window macOS did not restore, the most recently
        // active window) showed, from the app's own store.
        let claim = store.claim(key: restoredKey, restored: value) { id in (try? state.service.chat(id)) != nil }
        if case .open(let id) = claim { value = .chat(id) }
        switch value {
        // Q-015 r5: a restored chat that no longer exists (deleted since, or another data container's window state)
        // opened as an empty docked "chat" with Incognito disabled; the window starts on a new chat instead.
        case .chat(let id)? where (try? state.service.chat(id)) == nil: value = nil
        case .chat(let id)?: state.open(.chat(id))
        case .incognito?:
            value = nil
            state.newIncognitoChat()
        case nil: break
        }
        if sidebarCollapsed { state.columnVisibility = .detailOnly }
        record()
        store.scheduleExtras { ids in
            for id in ids { openWindow(id: MainWindowID.main, value: MainWindowValue.chat(id)) }
        }
    }

    /// Writes what the window shows (never an incognito chat).
    private func record() {
        guard !windowKey.isEmpty else { return }
        store.shown(key: windowKey, chatID: state.isIncognito ? nil : state.currentChatID, incognito: state.isIncognito)
    }
}

public extension View {
    /// Keeps the window's `WindowGroup` value and sidebar state in step with `state` (restored on relaunch).
    func windowRestoration(_ state: WindowState, value: Binding<MainWindowValue?>) -> some View {
        modifier(WindowRestoration(state: state, value: value))
    }
}
