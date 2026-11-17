// The mark of a connectable app, for every place that shows one (the Settings › Connections rows, the in-chat
// Connect card). Two sets, both bundled: the colour logos of the Connections catalogue (Resources/AppLogos/<slug>.png,
// 128 px, from tools/composio; read on first use and kept in memory) and eight monochrome vector templates in
// Resources/AppLogos.xcassets (Simple Icons, CC0, and two neutral marks drawn for this app where Simple Icons has
// none: see Resources/Onboarding/SOURCES.md), tinted like text so they follow light and dark. `color` picks the
// colour logo first (the Connections page); otherwise the monochrome mark comes first. An app with neither shows its
// initial. An app the relay's live list added (LiveAppCatalog) has no bundled logo: when its row appears, the logo
// is fetched once from the URL Composio lists for it (AppLogoCache: https and logos.composio.dev only, kept on
// disk), and the initial shows while it loads or when it fails.
import AntiChatDesign
import AntiChatTools
import AppKit
import SwiftUI

struct AppLogo: View {
    /// The toolkit slug (`gmail`); nil = an app the relay does not offer.
    let toolkit: String?
    /// The app's name, for the initial of an app without a mark.
    var name: String = ""
    /// The mark's edge in points.
    var size: CGFloat = 20
    /// Prefer the colour logo to the monochrome mark.
    var color = false

    static let bundled: Set<String> = ["gmail", "googlecalendar", "googledrive", "slack", "notion", "github", "linear", "outlook"]

    /// Counts the logos that arrived from Composio's logo host while this view was showing (redraws it).
    @State private var fetched = 0

    var body: some View {
        Group {
            if let toolkit, color || !Self.bundled.contains(toolkit), let image = Self.colorLogo(toolkit, fetched: fetched) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else if let toolkit, Self.bundled.contains(toolkit) {
                Image("app-\(toolkit)", bundle: .module).renderingMode(.template).resizable().scaledToFit()
            } else {
                let title = name.isEmpty ? toolkit.map(ComposioApps.title) ?? "" : name
                Text(verbatim: String(title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.8, weight: .semibold, design: .rounded))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color.textPrimary)
        .accessibilityHidden(true)
        .task(id: toolkit) {
            guard let toolkit, Self.colorLogo(toolkit) == nil, await Self.fetchLogo(toolkit) else { return }
            fetched += 1
        }
    }

    // MARK: Colour logos

    private static let cache = NSCache<NSString, NSImage>()
    private static let missing = NSImage()

    /// `Resources/AppLogos/<slug>.png`, nil when the app has none. Read once per slug (a miss is remembered too).
    /// `fetched` only ties the view's state to the lookup, so a logo that just arrived is drawn.
    static func colorLogo(_ slug: String, fetched: Int = 0) -> NSImage? {
        if let hit = cache.object(forKey: slug as NSString) { return hit === missing ? nil : hit }
        let safe = slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let image = (safe ? Bundle.module.url(forResource: slug, withExtension: "png", subdirectory: "AppLogos") : nil)
            .flatMap { NSImage(contentsOf: $0) }
        cache.setObject(image ?? missing, forKey: slug as NSString)
        return image
    }

    /// The logo of an app without a bundled one, from Composio's logo host (or its folder on disk). True = it is now
    /// in `cache`. No request for an app the current catalogue lists no logo URL for, or in Offline only.
    static func fetchLogo(_ slug: String) async -> Bool {
        guard let live = LiveAppCatalog.live, let url = live.catalog.app(slug)?.logoURL,
              let data = await live.logos.logo(slug: slug, url: url), let image = NSImage(data: data), image.isValid
        else { return false }
        cache.setObject(image, forKey: slug as NSString)
        return true
    }
}
