// CallIndicatorExtra (M3.T11 step 4; R-052 AC6): a minimal menu bar item that exists only while a voice conversation
// runs — template SF Symbol `waveform`, accessibility label `voice.callActive`; its menu has "Show chat" and End.
// M8.T13 (G-040, R-105): while the menu bar item is on it carries the call (waveform icon + these rows) and this
// indicator stays hidden; it shows only when the menu bar item is off.
import AntiChatDesign
import AntiChatHarness
import AppKit
import SwiftUI

public struct CallIndicatorExtra: Scene {
    @State private var calls = VoiceCalls.shared
    @State private var indicator = VoiceCallIndicator.shared

    public init() {}

    public var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { calls.isActive && !indicator.menuBarShowsCall }, set: { _ in })) {
            Button { show() } label: { Text(CopyKey("voice.showChat")) }
                .accessibilityIdentifier("callIndicator.showChat")
            Button { calls.current?.end() } label: { Text(CopyKey("voice.end")) }
                .accessibilityIdentifier("callIndicator.end")
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel(Text(CopyKey("voice.callActive")))
                .accessibilityIdentifier("callIndicator")
        }
    }

    @MainActor private func show() {
        NSApp.unhide(nil)
        NSApp.activate()
        calls.showChat?()
    }
}
