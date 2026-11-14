// M10.T07 step 2 (R-303 AC2): "What's new in AntiChat {version}" — once after an update, never on a first install,
// never during onboarding, off with Settings › Updates › "Show What's new after updates". Items come from the
// bundled notes/<version>.json (3–5, tools/release/notes-check.py). Own small sheet: the P-shell-18 fallback,
// chosen over adding WhatsNewKit (no new dependency for one sheet; A-M10-T07a).
import AntiChatDesign
import AntiChatFoundation
import SwiftUI

struct WhatsNewNotes: Decodable, Equatable {
    struct Item: Decodable, Equatable, Identifiable {
        let icon: String
        let title: String
        let body: String
        var id: String { title }
    }
    let version: String
    let items: [Item]

    static func load(version: String, bundle: Bundle = .main) -> WhatsNewNotes? {
        guard let url = bundle.url(forResource: version, withExtension: "json", subdirectory: "notes"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WhatsNewNotes.self, from: data)
    }
}

enum WhatsNewProvider {
    static let lastSeenKey = "whatsNew.lastSeenVersion"
    static let enabledKey = "whatsNew.enabled"

    /// Pure decision (unit-tested). A first launch (no last-seen version) only records the version.
    static func shouldShow(current: String, lastSeen: String?, enabled: Bool, onboarding: Bool, itemCount: Int) -> Bool {
        guard let lastSeen, enabled, !onboarding, (3 ... 5).contains(itemCount) else { return false }
        return lastSeen != current
    }

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Called once per launch after onboarding; returns the notes to show (and records the version either way).
    /// `defaults` is the Settings store (`UserDefaults.antichat`: the `-DefaultsSuite` of a test, else the app domain).
    static func notesToShow(defaults: UserDefaults = .antichat, onboarding: Bool, bundle: Bundle = .main) -> WhatsNewNotes? {
        let current = currentVersion
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // `-SimulateUpdatedFrom <v>` (HelpUITests): a launch with nothing recorded acts as an update from <v>.
        if let previous = LaunchOptions.current.simulateUpdatedFrom, defaults.string(forKey: lastSeenKey) == nil {
            defaults.set(previous, forKey: lastSeenKey)
        }
        #endif
        let notes = WhatsNewNotes.load(version: current, bundle: bundle)
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let show = shouldShow(current: current, lastSeen: defaults.string(forKey: lastSeenKey), enabled: enabled,
                              onboarding: onboarding, itemCount: notes?.items.count ?? 0)
        if !onboarding { defaults.set(current, forKey: lastSeenKey) }
        return show ? notes : nil
    }
}

struct WhatsNewSheet: View {
    let notes: WhatsNewNotes
    let onClose: () -> Void

    var body: some View {
        // M10 visual QA: the platform "What's new" layout — a centred title, the items as icon rows, and one full-width
        // primary Continue (`button.primary`; the bare default button rendered grey in an inactive sheet and white on
        // the pale accent in Dark).
        VStack(alignment: .leading, spacing: Spacing.space5) {
            Text(CopyText(CopyKey("whatsnew.title"), ["version": notes.version]))
                .typeStyle(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.space4) {
                ForEach(notes.items) { item in
                    HStack(alignment: .top, spacing: Spacing.space4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(Color.textPrimary)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title).typeStyle(.headline)
                            Text(verbatim: item.body).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Button(action: onClose) { Text(CopyKey("whatsnew.continue")).frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Spacing.space2)
        }
        .padding(Spacing.space6)
        .frame(width: 440)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("whatsNew")
    }
}
