// The Connections catalogue (ComposioCatalog): the JSON contract of tools/composio, its order, categories and
// search, and the built-in eight apps when the resource is missing or unreadable.
@testable import AntiChatTools
import Foundation
import Testing

@Suite struct ComposioCatalogTests {
    static let fixture = Data(#"""
    {"generated":"2026-11-16",
     "categories":[{"id":"popular","title":"Popular"},{"id":"communication","title":"Communication"},{"id":"productivity","title":"Productivity"}],
     "apps":[
      {"slug":"zoom","name":"Zoom","summary":"Video meetings","categories":["communication"],"auth":"oauth","popular":null,"logo":true},
      {"slug":"slack","name":"Slack","summary":"Team chat","categories":["popular","communication"],"auth":"oauth","popular":2,"logo":true},
      {"slug":"gmail","name":"Gmail","summary":"Read and manage Gmail","categories":["popular","communication"],"auth":"oauth","popular":1,"logo":true},
      {"slug":"cafe","name":"Café Planner","summary":"Plan café visits","categories":["productivity"],"auth":"apikey","popular":null,"logo":false},
      {"slug":"airtable","name":"Airtable","summary":"Bases and tables for a team","categories":["productivity"],"auth":"other","popular":null,"logo":false}
     ]}
    """#.utf8)

    @Test func decodesInDisplayOrder() {
        let c = ComposioCatalog(data: Self.fixture)
        #expect(c.categories.map(\.id) == ["popular", "communication", "productivity"])
        #expect(c.apps.map(\.slug) == ["gmail", "slack", "airtable", "cafe", "zoom"])  // popular by rank, then by name
        #expect(c.apps(in: "communication").map(\.slug) == ["gmail", "slack", "zoom"])
        #expect(c.apps(in: "nothing").isEmpty)
        #expect(c.app("cafe")?.name == "Café Planner" && c.app("nope") == nil)
    }

    @Test func searchIgnoresCaseAndAccents() {
        let c = ComposioCatalog(data: Self.fixture)
        #expect(c.search("CAFE").map(\.slug) == ["cafe"])
        #expect(c.search("café").map(\.slug) == ["cafe"])
        #expect(c.search("  gma ").map(\.slug) == ["gmail"])
        // Name first ("Slack"), then a summary match ("Bases and tables for a team" has no "sla"; "Team chat" is Slack's).
        #expect(c.search("team").map(\.slug) == ["slack", "airtable"])
        #expect(c.search("a").first?.slug == "airtable")  // a name that starts with the query comes first
        #expect(c.search("").isEmpty && c.search("zzz").isEmpty)
    }

    @Test func findsAnAppByWhatItIsCalled() {
        let c = ComposioCatalog(data: Self.fixture)
        #expect(c.slug(named: "Café  Planner!") == "cafe" && c.slug(named: "ZOOM") == "zoom" && c.slug(named: "planner") == nil)
        // The bundled catalogue: an app outside the built-in eight resolves by name, as the chat's connect_app needs.
        if let other = ComposioCatalog.shared.apps.first(where: { !ComposioApps.defaults.contains($0.slug) && $0.popular != nil }) {
            #expect(ComposioApps.resolve(other.name) == other.slug)
            #expect(ComposioApps.exact(other.name.lowercased()) == other.slug)
        }
        #expect(ComposioApps.resolve("email") == "gmail" && ComposioApps.resolve("no such app at all") == nil)
    }

    @Test func anOldRelayLinksOnlyItsList() throws {
        let old = try JSONDecoder().decode(RelayConnections.self, from: Data(#"{"toolkits":["gmail"],"connections":[]}"#.utf8))
        let new = try JSONDecoder().decode(RelayConnections.self, from: Data(#"{"toolkits":["gmail"],"connections":[],"all":true}"#.utf8))
        #expect(!old.linksAll && new.linksAll)
    }

    @Test func fallsBackToTheBuiltInApps() {
        for data in [nil, Data("not json".utf8), Data(#"{"categories":[],"apps":[]}"#.utf8)] {
            let c = ComposioCatalog(data: data)
            #expect(c.apps.map(\.slug) == ComposioApps.defaults)
            #expect(c.categories.map(\.id) == ["popular"])
            #expect(c.apps(in: "popular").count == 8)
        }
    }

    @Test func titlesComeFromTheKnownAppsThenTheCatalogue() {
        #expect(ComposioApps.title("googlecalendar") == "Google Calendar")
        #expect(ComposioApps.title("no_such_app") == "No_Such_App")
        if let other = ComposioCatalog.shared.apps.first(where: { !ComposioApps.defaults.contains($0.slug) }) {
            #expect(ComposioApps.title(other.slug) == other.name)
        }
    }
}
