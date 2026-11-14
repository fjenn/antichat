// M7.T14 step 2 (R-266; blueprint B §B4.2 step 2.4 "meta-tool escape hatch"; P-shell-12 after Osaurus
// `CapabilityTools.swift` discover/load): `find_tools {query}` lets the model reach a tool the selector left out.
// It is offered whenever some eligible tool was not (ToolSelector). TurnController answers the call itself — it is not
// a registry tool, so it never shows in the composer menus or on the Tools page — by ranking the turn's eligible tools
// for the query (ToolIndex), returning up to `max_per_step` of them (name + one-line description), and offering those
// on the next step (ToolSelector.afterDiscovery). Read-only, trusted output (tool names and our descriptions only).
import AntiChatEngineProtocol
import Foundation

public enum FindToolsTool {
    public static let name = "find_tools"
    public static let description = "Find a tool that is not in your current list: describe what you need in a few words; the matching tools are offered on your next step."
    public static let parameters = #"{"type":"object","properties":{"query":{"type":"string","description":"What the tool should do, in a few words"}},"required":["query"]}"#

    public static let schema = ToolSchema(name: name, description: description, parametersJSON: parameters)

    struct Args: Decodable { var query: String }

    /// The query of a call (nil = malformed).
    public static func query(_ argumentsJSON: String) -> String? {
        guard let a = try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8)) else { return nil }
        let q = a.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    /// The tools to bring in: relevant hits first, then the best-ranked others (the model asked explicitly), at most
    /// `limit`, never find_tools itself.
    public static func found(_ hits: [ToolIndex.Hit], limit: Int) -> [String] {
        let ranked = hits.filter(\.relevant) + hits.filter { !$0.relevant }
        return Array(ranked.map(\.name).filter { $0 != name }.prefix(max(0, limit)))
    }

    /// The result text for the model.
    public static func resultText(_ found: [ToolSchema]) -> String {
        guard !found.isEmpty else { return "No other tool matches. Answer with the tools you have." }
        let lines = found.map { t in "- \(t.name): \(ToolBlockRenderer.oneLineToolDescription(t.description) ?? "")" }
        return "These tools are available on your next step:\n" + lines.joined(separator: "\n")
    }
}
