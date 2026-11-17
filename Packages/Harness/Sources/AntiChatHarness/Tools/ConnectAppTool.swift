// Connecting an app from a chat. Two ways lead to the same Connect card in the reply (a `connectCard` activity, drawn
// by AntiChatUI's ConnectCardView, which runs the Composio sign-in):
//   1. `connect_app {app}`: a tool the model calls when the user asks to log in / connect, or a task needs an app that
//      is not connected. Like `find_tools` it is not a registry tool: TurnController offers and answers it itself. The
//      turn ends with the card; once the app is connected the chat runs the request again.
//   2. `directRequest`: a message that plainly says "log into GitHub" / "connect my Gmail" shows the card without the
//      model (small local models often answer "I can't log in for you" instead of calling a tool).
// `plan` is the other half: when apps are connected, the turn's prompt names them and keeps Composio's search and
// execute tools in the offered set, so "what's in my inbox" reaches Gmail instead of "I can't access your email".
// Names and slugs only; nothing here reads message content beyond matching app names (R-241).
import AntiChatEngineProtocol
import AntiChatNetwork
import AntiChatTools
import Foundation

public enum ConnectAppTool {
    public static let name = "connect_app"
    /// One sentence of at most 180 characters: the prompt carries only that much of a description (ToolBlockRenderer).
    public static let description = "Shows the user a Connect button to sign in to an app like Gmail, GitHub or Slack; "
        + "call it when they ask to log in or connect, or when a task needs an app that is not connected."
    public static let parameters = #"{"type":"object","properties":{"app":{"type":"string","description":"The app's name, e.g. Gmail"}},"required":["app"]}"#
    public static let schema = ToolSchema(name: name, description: description, parametersJSON: parameters)

    /// Whether a connection can be started now: this build has a relay, Offline only is off, and there is a network.
    public static func isAvailable(policy: NetworkPolicyStore = .shared, path: PathStatus = .shared) -> Bool {
        RelayClient.isAvailable() && !policy.offlineOnly && !path.isOffline
    }

    /// The app name of a call (nil = malformed).
    public static func app(_ argumentsJSON: String) -> String? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any],
              let a = (o["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
        return a
    }

    // MARK: The card

    /// What a `connectCard` activity carries: `tool` = the toolkit slug ("" = not an app the relay offers: the card
    /// links to Settings › Connections), `argumentsJSON` = `{"app": name, "direct": bool}`.
    public struct Card: Sendable, Equatable {
        public var toolkit: String?
        public var name: String
        /// The card answered a plain "connect X" message: nothing to run again once connected.
        public var direct: Bool
        public init(toolkit: String?, name: String, direct: Bool) {
            self.toolkit = toolkit; self.name = name; self.direct = direct
        }
    }

    public static func activity(id: String, app: String, toolkit: String?, direct: Bool) -> ToolActivity {
        let name = toolkit.map(ComposioApps.title) ?? app
        let args = (try? JSONSerialization.data(withJSONObject: ["app": name, "direct": direct], options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return ToolActivity(kind: .connectCard, id: id, tool: toolkit ?? "", state: .done, argumentsJSON: args)
    }

    public static func card(_ a: ToolActivity) -> Card? {
        guard a.kind == .connectCard else { return nil }
        let o = (try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any]
        return Card(toolkit: a.tool.isEmpty ? nil : a.tool, name: o?["app"] as? String ?? ComposioApps.title(a.tool),
                    direct: o?["direct"] as? Bool ?? false)
    }

    /// The tool result the model reads (and a later turn finds in the history).
    public static func result(app: String, connected: Bool) -> String {
        connected ? "\(app) is already connected. Use the connected-app tools to find and run the action."
            : "A Connect button for \(app) is now shown to the user. Nothing else can be done until they press it."
    }

    // MARK: The plain request

    private static let verbs = ["connect", "link", "log in", "login", "log into", "sign in", "signin", "sign into", "hook up", "authorize",
                                "authenticate"]
    private static let lead = ["please", "can you", "could you", "can i", "could i", "let me", "let s", "lets", "i want to", "i d like to",
                               "i would like to", "i need to", "help me", "hey", "hi", "ok", "okay", "now"]
    private static let filler: Set<String> = ["me", "my", "to", "into", "in", "with", "up", "the", "a", "an", "account", "app", "please",
                                              "now", "here", "for", "this", "chat", "you", "your", "our", "us", "and", "on"]

    /// The toolkit of a message that only asks to connect or sign in to one known app ("Let me log into GitHub",
    /// "connect my gmail account please"). Anything more (a task, two apps, an unknown app) is nil: the model decides.
    public static func directRequest(_ text: String?) -> String? {
        guard let text, text.count <= 80 else { return nil }
        var t = ComposioApps.normalized(text)
        var stripped = true
        while stripped {
            stripped = false
            for l in lead where t.hasPrefix(l + " ") { t = String(t.dropFirst(l.count + 1)); stripped = true }
        }
        guard let verb = verbs.sorted(by: { $0.count > $1.count }).first(where: { t.hasPrefix($0 + " ") }) else { return nil }
        let rest = t.dropFirst(verb.count + 1).split(separator: " ").map(String.init).filter { !filler.contains($0) }
        guard !rest.isEmpty, rest.count <= 2 else { return nil }
        return ComposioApps.exact(rest.joined(separator: " "))
    }

    /// The app a request needs when none that could serve it is connected: "summarise my latest emails" with no mail
    /// app connected → gmail. The card answers at once, without a model step (local models tend to reply "I can't
    /// access your email" instead of calling `connect_app`); once connected the request runs again.
    /// Only for a clear request for the user's own data or a plain order to act there (`ComposioApps.requested`): a
    /// sentence that merely contains "my drive" or "my schedule" goes to the model, which has `connect_app`.
    public static func neededApp(_ text: String?, connected: Set<String>) -> String? {
        guard let text, text.count <= 200 else { return nil }
        let asked = ComposioApps.requested(in: text)
        guard let first = asked.first, !asked.contains(where: connected.contains) else { return nil }
        return first
    }

    /// The app whose Connect card answers `text` instead of the model (nil = the model answers), and whether the
    /// message only asked to connect (`direct`: nothing to run again afterwards).
    public static func cardApp(_ text: String?, connected: Set<String>) -> (toolkit: String, direct: Bool)? {
        if let t = directRequest(text) { return (t, true) }
        return neededApp(text, connected: connected).map { ($0, false) }
    }

    /// Whether `text` talks about connecting or signing in at all (then `connect_app` is kept in the offered set).
    static func mentionsConnecting(_ text: String) -> Bool {
        let t = " \(ComposioApps.normalized(text)) "
        return verbs.contains { t.contains(" \($0) ") }
    }

    /// A short reply that only says what it is about to do with a tool ("Let me search for…", "Now I'll send the
    /// email…") — and then did nothing. Used once per turn, only when the connected-app tools were offered and no tool
    /// was called.
    public static func announcesToolUse(_ reply: String) -> Bool {
        guard reply.count <= 600 else { return false }
        return reply.range(of: #"\b(let me|i'll|i’ll|i will|i need to|i am going to|i'm going to)\b[^.!?\n]{0,80}\b(search|find|look|check|send|fetch|get|use|call|create|retrieve)\b"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: The turn's tools and prompt

    public struct Plan: Sendable, Equatable {
        /// Keep Composio's search + execute tools in the offered set whatever the tier's cap (never a forced call).
        public var pinsComposio = false
        /// Keep `connect_app` in the offered set.
        public var pinsConnect = false
        /// The connected apps' names for the prompt (empty = none, or no Composio tools this turn).
        public var apps: [String] = []
        /// The connected apps the newest message is about ("send an email…" → Gmail): `turnLine` reminds the model of them
        /// right next to the message, and a reply that says it cannot is asked once more.
        public var wanted: [String] = []
    }

    /// The line next to the user's message for a request about a connected app. The tool-use layer already says the
    /// same, but far from the message; a small model then answers "I cannot send emails" from habit (or from a skill's
    /// text about drafting).
    public static func turnLine(wanted: [String], search: String?, execute: String?, offered: [String]) -> String? {
        guard !wanted.isEmpty, let search, let execute, offered.contains(search), offered.contains(execute) else { return nil }
        return "\(wanted.joined(separator: ", ")) is connected. If this request needs it (reading, searching, sending or changing "
            + "something there), call \(search) now, then \(execute). Do not answer that you cannot do it."
    }

    /// A short reply that says it has no access or cannot do it ("I cannot send emails directly").
    public static func refusesAccess(_ reply: String) -> Bool {
        guard reply.count <= 600 else { return false }
        return reply.range(of: #"\b(cannot|can't|can’t|unable to|not able to|don't have (access|the ability)|do not have (access|the ability))\b"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// `userTexts` = the newest user messages (newest last; a follow-up like "reply to the second one" names no app, so
    /// the one before counts too). `connected` = toolkit slugs. `hasComposio` = Composio's search and execute tools are
    /// eligible this turn. `roomy` = a tier that is not held to four tools per step: there the pair is always kept.
    public static func plan(userTexts: [String], connected: Set<String>, connectOffered: Bool, hasComposio: Bool, roomy: Bool) -> Plan {
        var plan = Plan()
        if hasComposio, !connected.isEmpty {
            plan.apps = ComposioApps.known.filter { connected.contains($0.slug) }.map(\.title)
                + connected.filter { s in !ComposioApps.known.contains { $0.slug == s } }.sorted().map(ComposioApps.title)
            let wanted = userTexts.flatMap { ComposioApps.named(in: $0) + ComposioApps.about(in: $0) }
            plan.pinsComposio = roomy || wanted.contains { connected.contains($0) }
            if let newest = userTexts.last {
                let now = Set(ComposioApps.named(in: newest) + ComposioApps.about(in: newest)).intersection(connected)
                plan.wanted = ComposioApps.known.filter { now.contains($0.slug) }.map(\.title)
                    + now.subtracting(ComposioApps.defaults).sorted().map(ComposioApps.title)
            }
        }
        if connectOffered, let newest = userTexts.last {
            let named = ComposioApps.named(in: newest), cued = ComposioApps.cued(in: newest)
            let missing = named.contains { !connected.contains($0) } || (!cued.isEmpty && !cued.contains { connected.contains($0) })
            plan.pinsConnect = missing || mentionsConnecting(newest)
        }
        return plan
    }

    /// The tool-use layer's line about the connected apps, worded for what this step offers (nil = nothing to say).
    public static func clause(apps: [String], search: String?, execute: String?, offered: [String]) -> String? {
        guard !apps.isEmpty, let search, let execute else { return nil }
        let how: String
        if offered.contains(search), offered.contains(execute) {
            how = "call \(search) to find the right action, then \(execute) to run it (ask for at most 10 items). "
                + "The result comes straight back to you: answer the user from it."
        } else if offered.contains(FindToolsTool.name) {
            how = "call \(FindToolsTool.name) to load their tools."
        } else {
            return nil
        }
        return "The user has connected these apps: \(apps.joined(separator: ", ")). You can read and act in them: \(how) "
            + "Never say you cannot access a connected app. Do not mention tool names or describe these steps to the user; "
            + "just do it and give the answer."
    }
}
