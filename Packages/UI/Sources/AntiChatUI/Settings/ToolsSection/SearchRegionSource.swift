// R-091 AC3 / R-109 (M8.T08 × M7): the source of the search region hint. nil unless Settings › Capabilities ›
// "Use my approximate location for search" is on (the default) and macOS Location is granted (LocationPermission);
// then the Mac's region as an ISO country code. On, with macOS never asked: this search gets no hint and the
// just-in-time explainer is offered once (SearchLocationPrompt). Nothing is located or geocoded: country level only, offline, never coordinates.
// The composition root installs it (`SearchRegion.use(SearchRegionSource.live)`); SearchRegion validates the code and
// an incognito search never asks.
import AntiChatPlatform
import AntiChatTools
import Defaults
import Foundation

public enum SearchRegionSource {
    /// The macOS Location status (tests replace it).
    nonisolated(unsafe) static var status: @Sendable () -> LocationAuthorization = { LocationPermission.currentStatus() }
    nonisolated(unsafe) static var region: @Sendable () -> String? = { Locale.current.region?.identifier }

    /// A search would have used location but macOS has not been asked (tests replace it).
    nonisolated(unsafe) static var offerExplainer: @Sendable () -> Void = {
        Task { @MainActor in SearchLocationPrompt.shared.searchWantsLocation() }
    }

    @Sendable public static func live() -> String? {
        guard Defaults[.searchUsesLocation] else { return nil }
        switch status() {
        case .granted: return region()
        case .notDetermined: offerExplainer(); return nil
        case .denied, .restricted, .servicesOff: return nil
        }
    }
}
