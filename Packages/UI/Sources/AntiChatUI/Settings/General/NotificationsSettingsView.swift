// M8.T12 steps 2 and 5 (R-108 AC1–AC2; settings-map §1): Settings › General › Notifications — "Notify me" (Only
// when AntiChat isn't in front (default) / Always / Never), the four category toggles (all on), and "Sound" (System
// default, the names in /System/Library/Sounds, None; the choice plays once when it changes). While macOS has
// notifications off for AntiChat, the banner `permission.notifications.off` with [Open System Settings] sits on top
// (re-checked on app activation).
import AntiChatDesign
import AntiChatPlatform
import AppKit
import Defaults
import SwiftUI

struct NotificationsSettingsView: View {
    @Default(.notifyWhen) private var when
    @Default(.notifyResponses) private var responses
    @Default(.notifyMedia) private var media
    @Default(.notifyDownloads) private var downloads
    @Default(.notifyUpdates) private var updates
    @Default(.notificationSound) private var sound
    @State private var permissions = PermissionCoordinator.shared
    private let soundNames = NotificationSound.systemSoundNames()

    var body: some View {
        SettingsItem("notifyWhen") {
            Picker(selection: $when) {
                Text(CopyKey("set.notif.unfocused")).tag(NotifyWhen.unfocused.rawValue)
                Text(CopyKey("set.notif.always")).tag(NotifyWhen.always.rawValue)
                Text(CopyKey("set.notif.never")).tag(NotifyWhen.never.rawValue)
            } label: { Text(CopyKey("set.notif.when")) }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.notifyWhen")
        }
        toggle("notifyResponses", $responses, "set.notif.responses")
        toggle("notifyMedia", $media, "set.notif.media")
        toggle("notifyDownloads", $downloads, "set.notif.downloads")
        toggle("notifyUpdates", $updates, "set.notif.updates")
        SettingsItem("notificationSound") {
            Picker(selection: $sound) {
                Text(CopyKey("set.notif.sound.default")).tag("default")
                ForEach(soundNames, id: \.self) { Text(verbatim: $0).tag($0) }
                Text(CopyKey("set.notif.sound.none")).tag("none")
            } label: { Text(CopyKey("set.notif.sound")) }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(when == NotifyWhen.never.rawValue)
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.notificationSound")
        }
        .onChange(of: sound) { _, name in Self.preview(name) }
        .task { _ = await permissions.status(.notifications) }
    }

    private func toggle(_ id: String, _ value: Binding<Bool>, _ label: String) -> some View {
        SettingsItem(id) {
            Toggle(isOn: value) { Text(CopyKey(label)) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .disabled(when == NotifyWhen.never.rawValue)
                .probeID("settings.control.\(id)")
        }
    }

    /// Plays the chosen sound once (System default: the system alert sound; None: nothing).
    static func preview(_ name: String) {
        switch NotificationSound(rawValue: name) {
        case .none: return
        case .systemDefault: NSSound.beep()
        case .named(let n): NSSound(named: NSSound.Name(n))?.play()
        }
    }
}
