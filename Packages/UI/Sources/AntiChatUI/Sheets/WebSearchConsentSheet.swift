// WebSearchConsentSheet (M7.T03 step 2; R-080 AC1; S-24; copy `search.consent.*`): any off → on transition of web
// search outside onboarding (the Settings row, the composer's Web search row, `hint.fresh.on` in M7.T05) asks first.
// The body names the enabled engines (`EngineRegistry.enabledNames`) and says only the search words are sent.
// [Turn on] switches the gate's `.search` category on (`net.category.search`); [Not now] leaves it off.
import AntiChatDesign
import AntiChatNetwork
import AntiChatTools
import Observation
import SwiftUI

@MainActor
@Observable
public final class WebSearchConsent {
    public static let shared = WebSearchConsent()

    /// Which window presents the sheet (the main window or Settings), so only one shows it.
    public enum Origin: Sendable, Equatable { case main, settings }

    public private(set) var presented: Origin?
    @ObservationIgnored private var done: (@MainActor (Bool) -> Void)?
    @ObservationIgnored let policy: NetworkPolicyStore
    @ObservationIgnored let registry: EngineRegistry
    /// Every answer, for probes and tests.
    public private(set) var answers: [Bool] = []

    public init(policy: NetworkPolicyStore = .shared, registry: EngineRegistry = .shared) {
        self.policy = policy
        self.registry = registry
    }

    /// Asks before turning search on. Already on: `done(true)` at once, no sheet.
    public func request(from origin: Origin, done: @escaping @MainActor (Bool) -> Void) {
        if policy.storedValue(.search) { done(true); return }
        self.done?(false)
        self.done = done
        presented = origin
    }

    /// [Turn on] / [Not now].
    public func answer(_ on: Bool) {
        if on { policy.setEnabled(.search, true) }
        answers.append(on)
        presented = nil
        let d = done
        done = nil
        d?(on)
    }

    /// "DuckDuckGo, Brave, Mojeek, Startpage and Wikipedia" (the enabled engines, list-formatted for the locale).
    public var engines: String { ListFormatter.localizedString(byJoining: registry.enabledNames) }

    func binding(_ origin: Origin) -> Binding<Bool> {
        Binding(get: { self.presented == origin }, set: { if !$0, self.presented == origin { self.answer(false) } })
    }
}

struct WebSearchConsentSheet: View {
    let consent: WebSearchConsent

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: "globe").font(.system(size: 20, weight: .regular)).foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
                // VQ-M11 S-24: the sheet title size (title2 was oversized for a 440 pt sheet).
                Text(CopyKey("search.consent.title")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            }
            Text(CopyText(CopyKey("search.consent.body"), ["engines": consent.engines]))
                .typeStyle(.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .probeID("search.consent.body")
            HStack {
                Spacer()
                Button { consent.answer(false) } label: { Text(CopyKey("search.consent.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .probeID("search.consent.cancel")
                Button { consent.answer(true) } label: { Text(CopyKey("search.consent.on")) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .probeID("search.consent.on")
            }
        }
        .padding(Spacing.space6)
        .frame(width: 440)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("search.consentSheet")
    }
}

extension View {
    /// Presents the web search consent sheet when `origin` asked for it.
    public func webSearchConsentSheet(_ origin: WebSearchConsent.Origin, consent: WebSearchConsent = .shared) -> some View {
        sheet(isPresented: consent.binding(origin)) { WebSearchConsentSheet(consent: consent) }
    }
}
