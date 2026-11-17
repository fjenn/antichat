// The apps people connect through Composio, as the chat needs them: what each is called ("gmail", "google mail"),
// the words that mean "my data in that app" ("my inbox"), and which ones are connected right now. The connected set
// is a small process-wide cache of the relay's `/v1/connections` answer, written by every `ComposioConnection`
// read (Settings, the in-chat Connect card, the launch / per-turn refresh), so a chat learns about a new connection
// without a restart. Names and slugs only: never message content.
import Foundation
import Synchronization

public enum ComposioApps {
    public struct App: Sendable, Equatable {
        /// The Composio toolkit slug the relay links (`gmail`, `googlecalendar`).
        public let slug: String
        public let title: String
        /// What people call the app, lowercase ("gmail", "google mail").
        let names: [String]
        /// What the user's own data in an app of this kind is called: "my inbox", "my latest emails" (`cued`); lowercase.
        let cues: [String]
        /// One-word kinds a model may send instead of the name ("email").
        let kinds: [String]
    }

    private static let mail = ["email", "emails", "e mail", "e mails", "mail", "mails", "inbox"]
    private static let calendar = ["calendar", "schedule", "meetings", "appointments"]

    /// The default allow-list (architecture §8.3), in the order Settings shows it.
    public static let known: [App] = [
        App(slug: "gmail", title: "Gmail", names: ["gmail", "google mail"], cues: mail, kinds: ["email", "e mail", "mail", "emails"]),
        App(slug: "googlecalendar", title: "Google Calendar", names: ["google calendar", "googlecalendar", "gcal"], cues: calendar,
            kinds: ["calendar"]),
        App(slug: "googledrive", title: "Google Drive", names: ["google drive", "googledrive", "gdrive"], cues: ["drive"],
            kinds: ["drive"]),
        App(slug: "slack", title: "Slack", names: ["slack"], cues: [], kinds: []),
        App(slug: "notion", title: "Notion", names: ["notion"], cues: [], kinds: []),
        App(slug: "github", title: "GitHub", names: ["github", "git hub"],
            cues: ["repos", "repositories", "pull requests", "prs"], kinds: []),
        App(slug: "linear", title: "Linear", names: ["linear"], cues: [], kinds: []),
        App(slug: "outlook", title: "Outlook", names: ["outlook"], cues: mail + calendar, kinds: []),
    ]

    public static let defaults: [String] = known.map(\.slug)

    /// The display name of a toolkit slug (a brand name, not copy): the catalogue's for an app outside `known`.
    public static func title(_ slug: String) -> String {
        known.first { $0.slug == slug }?.title ?? ComposioCatalog.shared.app(slug)?.name ?? slug.capitalized
    }

    /// Lowercase letters and digits, single spaces ("Log into Git-Hub!" → "log into git hub").
    public static func normalized(_ s: String) -> String {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }

    private static func has(_ text: String, _ phrase: String) -> Bool { " \(text) ".contains(" \(phrase) ") }

    /// The apps `text` names outright: the known ones, and any other connected app by its catalogue name (the
    /// catalogue's thousand names are never scanned for an app that is not connected).
    public static func named(in text: String) -> [String] {
        let t = normalized(text)
        return known.filter { a in a.names.contains { has(t, $0) } }.map(\.slug)
            + connected.filter { s in !defaults.contains(s) && has(t, normalized(title(s))) }.sorted()
    }

    /// The apps whose kind of data `text` asks about: "my" and, at most one word later, what it is called ("my inbox",
    /// "my latest emails" → gmail, outlook; not "write an email to my boss").
    public static func cued(in text: String) -> [String] {
        let words = normalized(text).split(separator: " ")
        let after = words.indices.filter { words[$0] == "my" }.map { " " + words[($0 + 1)...].prefix(3).joined(separator: " ") + " " }
        func owns(_ cue: String) -> Bool {
            after.contains { $0.hasPrefix(" \(cue) ") || $0.drop { $0 == " " }.drop { $0 != " " }.hasPrefix(" \(cue) ") }
        }
        return known.filter { $0.cues.contains(where: owns) }.map(\.slug)
    }

    // MARK: A clear request for the user's own data

    /// The kinds of data a request can be about, with the apps that hold them (the first is the one a card offers).
    private enum DataKind: CaseIterable {
        case mail, calendar, drive, code

        var apps: [String] {
            switch self {
            case .mail: ["gmail", "outlook"]
            case .calendar: ["googlecalendar", "outlook"]
            case .drive: ["googledrive"]
            case .code: ["github"]
            }
        }

        /// What the data is called, as normalized words (the app ships en, nl, de, fr, es, pt; a few words each).
        var nouns: [[String]] {
            switch self {
            case .mail:
                [["e", "mails"], ["e", "mail"], ["emails"], ["email"], ["mails"], ["mail"], ["inbox"], ["posteingang"], ["postvak"],
                 ["courriels"], ["courriel"], ["correos"], ["correo"]]
            case .calendar:
                [["calendar"], ["schedule"], ["meetings"], ["appointments"], ["kalender"], ["agenda"], ["calendrier"], ["calendario"],
                 ["calendário"], ["termine"], ["afspraken"]]
            case .drive: [["drive"], ["gdrive"]]
            case .code: [["pull", "requests"], ["repos"], ["repositories"], ["prs"]]
            }
        }
    }

    private static let possessives: Set<String> = ["my", "mijn", "mein", "meine", "meinen", "meinem", "meiner", "mon", "ma", "mes",
                                                   "mi", "mis", "meu", "minha", "meus", "minhas"]
    /// Words that ask to see or look through something (a retrieval verb or a question word).
    private static let askWords: Set<String> = [
        "show", "summarize", "summarise", "check", "find", "read", "list", "search", "fetch", "scan", "look", "go", "what", "whats",
        "anything", "triage",
        "toon", "bekijk", "lees", "zoek", "doorzoek", "vat", "wat",
        "zeig", "zeige", "lies", "prüfe", "prüf", "checke", "suche", "durchsuche", "fasse", "was",
        "montre", "affiche", "lis", "vérifie", "cherche", "résume",
        "muestra", "muéstrame", "lee", "revisa", "busca", "resume", "resumen", "qué",
        "mostra", "mostre", "leia", "verifica", "verifique", "procura", "resuma", "que",
    ]
    /// The small words allowed between the asking word and "my" ("show me all of my…", "what do I have on my…").
    private static let askFillers: Set<String> = [
        "me", "us", "all", "of", "through", "at", "in", "on", "up", "for", "into", "inside", "s", "is", "are", "there", "do", "i",
        "have", "got", "ve", "new", "please", "quickly",
        "er", "staat", "op", "eens", "even", "mir", "mal", "bitte", "steht", "im", "auf", "moi", "dans", "hay", "en", "os", "as",
        "tem", "no", "na",
    ]
    /// Words allowed between "my" and the noun ("my latest emails", "my last 3 emails", "my Google Drive files").
    private static let dataModifiers: Set<String> = [
        "latest", "recent", "newest", "new", "unread", "last", "next", "upcoming", "today", "todays", "s", "google", "gmail",
        "outlook", "github", "work", "personal", "important", "starred", "open", "first",
        "laatste", "nieuwste", "nieuwe", "ongelezen", "recente", "letzten", "neuesten", "neuen", "ungelesenen", "aktuellen",
        "derniers", "nouveaux", "récents", "últimos", "nuevos", "recientes", "novos", "recentes",
    ]
    /// A noun followed by one of these is not the user's data in an app ("my email address", "my calendar app").
    private static let notData: Set<String> = [
        "address", "addresses", "signature", "template", "templates", "draft", "drafts", "app", "apps", "client", "provider",
        "password", "account", "accounts", "settings", "setup", "marketing", "campaign", "campaigns", "list", "newsletter",
        "etiquette", "skills", "habits", "server", "domain", "is", "was", "has", "got", "keeps",
    ]
    /// "drive" alone is a disk or a commute; it is Google Drive only with these after it (or "google" before it).
    private static let driveThings: Set<String> = ["files", "file", "folder", "folders", "docs", "doc", "documents", "document"]
    /// A request with any of these is a how-to, an opinion or a writing job: the model answers it.
    private static let notARequest = ["how do", "how to", "how can", "how should", "how would", "why", "explain", "tips", "advice",
                                      "should i", "typo", "typos", "grammar", "spelling", "proofread", "rewrite", "draft", "template",
                                      "best way"]

    private static let sendVerbs: Set<String> = ["send", "stuur", "verstuur", "sende", "schick", "schicke", "envoie", "envía", "envia",
                                                 "manda", "envie", "mande"]
    private static let sendArticles: Set<String> = ["an", "a", "the", "this", "that", "quick", "short", "brief", "een", "eine", "einen",
                                                    "un", "une", "um", "uma", "kurze", "korte"]
    private static let sendTo: Set<String> = ["to", "naar", "aan", "an", "à", "a", "para"]
    private static let requestLeads = ["please", "pls", "can you", "could you", "would you", "hey", "hi", "ok", "okay", "now"]
    private static let addVerbs: Set<String> = ["add", "put", "schedule", "book", "create"]

    /// The apps whose data `text` clearly asks for: an asking word, then "my", then what the data is called ("summarize
    /// my latest emails", "what's on my calendar", "list my Drive files"), or a plain order to act there ("send an email
    /// to…", "add … to my calendar"). Strict on purpose: this decides that the Connect card replaces the model's answer,
    /// so a sentence that merely contains "my drive" or "my schedule" ("My hard drive is full", "help me plan my
    /// schedule") is not one. When unsure the answer is empty and the model decides (it has `connect_app`).
    public static func requested(in text: String) -> [String] {
        let t = normalized(text)
        guard !notARequest.contains(where: { has(t, $0) }) else { return [] }
        let w = t.split(separator: " ").map(String.init)
        var kinds: [DataKind] = []
        func add(_ k: DataKind) { if !kinds.contains(k) { kinds.append(k) } }

        for i in w.indices where askWords.contains(w[i]) {
            var j = i + 1
            while j < w.count, j - i <= 4, askFillers.contains(w[j]) { j += 1 }
            guard j < w.count, possessives.contains(w[j]) else { continue }
            var k = j + 1, modifiers: [String] = []
            while k < w.count, modifiers.count < 2, dataModifiers.contains(w[k]) || Int(w[k]) != nil {
                // "mail" / "e" are nouns here, never modifiers; an app name before the noun is ("my gmail inbox").
                modifiers.append(w[k]); k += 1
            }
            for kind in DataKind.allCases {
                guard let noun = kind.nouns.first(where: { Array(w[k...].prefix($0.count)) == $0 }) else { continue }
                let next = k + noun.count < w.count ? w[k + noun.count] : nil
                if let next, notData.contains(next) { continue }
                if noun == ["drive"], !modifiers.contains("google"), !(next.map(driveThings.contains) ?? false) { continue }
                add(kind)
            }
        }

        // "Send an email to …" / "add … to my calendar": an order, at the start of the message.
        var lead = t
        var stripped = true
        while stripped {
            stripped = false
            for l in requestLeads where lead.hasPrefix(l + " ") { lead = String(lead.dropFirst(l.count + 1)); stripped = true }
        }
        let o = lead.split(separator: " ").map(String.init)
        if let first = o.first, sendVerbs.contains(first) {
            var i = 1
            while i < o.count, i <= 3, sendArticles.contains(o[i]) { i += 1 }
            if let noun = DataKind.mail.nouns.first(where: { Array(o[i...].prefix($0.count)) == $0 }), noun != ["inbox"],
               i + noun.count < o.count, sendTo.contains(o[i + noun.count]) { add(.mail) }
        }
        if let first = o.first, addVerbs.contains(first),
           lead.range(of: #" (to|on|in) my (google |work |personal )?calendar( |$)"#, options: .regularExpression) != nil { add(.calendar) }

        var out: [String] = []
        for k in kinds { for a in k.apps where !out.contains(a) { out.append(a) } }
        return out
    }

    /// The apps whose kind of thing `text` mentions at all ("send an email to…" → gmail, outlook). Loose on purpose: it
    /// only decides whether a connected app's tools stay offered on a small tier, never that anything runs.
    public static func about(in text: String) -> [String] {
        let t = normalized(text)
        return known.filter { a in a.cues.contains { has(t, $0) } }.map(\.slug)
    }

    /// The app `name` is exactly ("github", "Google Calendar", any catalogue app's name: "Trello"), nil for anything else.
    public static func exact(_ name: String) -> String? {
        let t = normalized(name)
        return known.first { normalized($0.title) == t || $0.names.contains(t) }?.slug ?? ComposioCatalog.shared.slug(named: t)
    }

    /// The toolkit for an app name as a person or a model wrote it ("GitHub", "my gmail account", "email"); nil = not
    /// a known or catalogue app. `offered` = the relay's list (`*` = any toolkit: a one-word name is then its own slug).
    public static func resolve(_ name: String, offered: [String] = ComposioApps.offered) -> String? {
        let t = normalized(name), squashed = t.replacingOccurrences(of: " ", with: "")
        guard !t.isEmpty else { return nil }
        if let a = known.first(where: { $0.slug == squashed || normalized($0.title) == t || $0.names.contains(t) || $0.kinds.contains(t) }) {
            return a.slug
        }
        if offered.contains(squashed) { return squashed }
        if let s = ComposioCatalog.shared.slug(named: t) { return s }  // any catalogue app by its exact name ("Trello")
        if let a = known.first(where: { a in a.names.contains { has(t, $0) } }) { return a.slug }
        return nil
    }

    // MARK: Connected now

    struct Snapshot { var connected: Set<String> = []; var offered: [String] = []; var all = false; var at: ContinuousClock.Instant? }
    private static let state = Mutex(Snapshot())

    /// The toolkits with an active connection (empty until the relay answered once).
    public static var connected: Set<String> { state.withLock { $0.connected } }
    /// The toolkits the relay offers (the defaults until it answered; without `*`).
    public static var offered: [String] { state.withLock { $0.offered.isEmpty ? defaults : $0.offered } }

    /// The relay's answer (nil = there is no Composio connection any more).
    public static func update(_ r: RelayConnections?) {
        state.withLock {
            $0.connected = Set((r?.connections ?? []).filter(\.isActive).map(\.toolkit))
            $0.offered = (r?.toolkits ?? []).filter { $0 != "*" }
            $0.all = r?.linksAll ?? false
            $0.at = .now
        }
    }

    /// Whether the cache is older than `ttl` (or was never filled).
    public static func isStale(_ ttl: Duration = .seconds(60)) -> Bool {
        state.withLock { $0.at.map { ContinuousClock.now - $0 > ttl } ?? true }
    }
}
