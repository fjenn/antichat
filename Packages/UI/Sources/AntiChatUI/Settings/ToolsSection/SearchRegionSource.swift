// R-091 AC3 / R-109 (M8.T08 × M7): the source of the search region hint. nil unless Settings › Tools & Connections ›
// "Use my approximate location for search" is on and macOS Location is granted (LocationPermission); then the Mac's
// region as an ISO country code. Nothing is located or geocoded: country level only, offline, never coordinates.
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

    @Sendable public static func live() -> String? {
        guard Defaults[.searchUsesLocation], status() == .granted else { return nil }
        return region()
    }
}
