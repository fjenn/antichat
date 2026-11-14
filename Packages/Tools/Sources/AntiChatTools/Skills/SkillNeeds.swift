// M7.T12 step 6 (R-082 AC4): a skill whose `allowed-tools` names web search or a connection that is off or offline
// says so — "needs Web search (off)" on its row and on its activity line (`skills.needs`). Skills themselves are
// instructions: they work offline and nothing in the skill path touches the network.
import Foundation

public struct SkillNeed: Sendable, Hashable {
    public enum Feature: Sendable, Hashable {
        case webSearch
        /// A connection by name (an `mcp__<server>__…` / `mcp:<server>` entry in allowed-tools).
        case connection(String)
    }
    public enum State: String, Sendable, Hashable { case off, offline }
    public let feature: Feature
    public let state: State

    public init(feature: Feature, state: State) { self.feature = feature; self.state = state }

    /// Persisted form for the activity line (`ToolActivity.result`): "web|off", "conn:<name>|offline".
    public var token: String {
        switch feature {
        case .webSearch: "web|\(state.rawValue)"
        case .connection(let n): "conn:\(n)|\(state.rawValue)"
        }
    }

    public init?(token: String) {
        let parts = token.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let st = State(rawValue: parts[1]) else { return nil }
        if parts[0] == "web" { self.init(feature: .webSearch, state: st) }
        else if parts[0].hasPrefix("conn:") { self.init(feature: .connection(String(parts[0].dropFirst(5))), state: st) }
        else { return nil }
    }
}

public enum SkillNeeds {
    /// Tool names that mean "web search" in skills written for AntiChat or for other agents.
    static let webTools: Set<String> = ["web_search", "read_url", "websearch", "webfetch", "web_fetch", "fetch", "browser"]

    /// What `allowedTools` needs that is unavailable now. `webSearch` = the live search state; `connections` = the
    /// user's connections by lowercased name → on (absent = not added: reported as off).
    public static func evaluate(allowedTools: [String], webSearch: WebSearchAvailability.State,
                                connections: [String: Bool] = [:]) -> [SkillNeed] {
        var out: [SkillNeed] = []
        let offline = webSearch == .offlineOnly || webSearch == .noNetwork
        let names = allowedTools.map { tool -> String in
            // "WebFetch(domain:…)" / "Bash(git:*)" → the tool part.
            String(tool.prefix { $0 != "(" }).lowercased()
        }
        if names.contains(where: webTools.contains), webSearch != .available {
            out.append(SkillNeed(feature: .webSearch, state: offline ? .offline : .off))
        }
        var seen = Set<String>()
        for n in names {
            let server: String?
            if n.hasPrefix("mcp__") { server = n.dropFirst(5).components(separatedBy: "__").first }
            else if n.hasPrefix("mcp:") { server = n.dropFirst(4).components(separatedBy: ":").first }
            else { server = nil }
            guard let s = server, !s.isEmpty, seen.insert(s).inserted else { continue }
            if offline { out.append(SkillNeed(feature: .connection(s), state: .offline)) }
            else if connections[s] != true { out.append(SkillNeed(feature: .connection(s), state: .off)) }
        }
        return out
    }
}
