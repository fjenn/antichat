// "Use my approximate location for search" is on by default (owner 2026-11-16), and macOS is asked just in time
// (R-091 AC3, R-109): the first web search of a normal chat that would use location, while macOS has never been
// asked, shows the explainer (`perm.location.why`) as a calm row above the composer (`LocationExplainerBanner`) with
// [Not now] [Continue]. The search itself does not wait: it runs without location. Continue → the macOS dialog
// (LocationPermission.request, the app's one request path). Not now → the setting turns off. Either answer is
// remembered, so the row never comes back by itself; Settings › Capabilities › Advanced asks again when the user
// turns the switch on. Never at launch, never during onboarding, never from an incognito chat (SearchRegion).
import AntiChatPlatform
import Defaults
import Foundation
import Observation

@MainActor @Observable
public final class SearchLocationPrompt {
    public static let shared = SearchLocationPrompt()

    /// App state in the Settings store (not a setting): the explainer was answered, here or in Settings.
    static let askedKey = "searchLocationAsked"

    /// The explainer row is on screen.
    public private(set) var isShowing = false
    @ObservationIgnored private let location: LocationPermission
    @ObservationIgnored private let defaults: UserDefaults
    /// A main window can show the row (none: nothing is asked; the next search tries again).
    @ObservationIgnored private let canShow: @MainActor () -> Bool

    init(location: LocationPermission = .shared, defaults: UserDefaults = .antichat,
         canShow: @escaping @MainActor () -> Bool = {
             IncognitoQuitGuard.states.contains { PermissionExplainers.canAnswer(in: $0.window) }
         }) {
        self.location = location
        self.defaults = defaults
        self.canShow = canShow
    }

    var hasAsked: Bool { defaults.bool(forKey: Self.askedKey) }

    /// The user answered the explainer (this row, or the sheet of the Settings switch).
    func markAsked() { defaults.set(true, forKey: Self.askedKey) }

    /// A web search just ran that would have carried the location hint (SearchRegionSource).
    public func searchWantsLocation() {
        guard !isShowing, Defaults[.searchUsesLocation], !hasAsked else { return }
        location.refresh()
        guard location.status == .notDetermined, canShow() else { return }
        isShowing = true
        PermissionCoordinator.shared.recordExplained(.location)  // R-109: the explainer comes before the request
    }

    /// [Continue] (true): the macOS dialog. [Not now] (false): searches stay without location and the switch is off.
    public func respond(_ allow: Bool) {
        guard isShowing else { return }
        isShowing = false
        markAsked()
        if allow { location.request() } else { Defaults[.searchUsesLocation] = false }
    }
}
