// M7.T14 step 4 (R-267 AC1; blueprint B §B4.5): unavailable online tools are invisible to the model. Before the prompt
// is rendered, every tool that needs the network is dropped when it cannot work now:
//   - `web_search`, `read_url`: the Web search switch (the gate's `.search` category), Offline only, no network path
//     (WebSearchAvailability, the same state the registry entries and the composer chip follow);
//   - every remote MCP tool: Offline only, the `.mcp` category off, no network path;
//   - every Composio tool (relay): Offline only, the `.relay` category off, no network path.
// Local tools are never touched, so offline the chat works exactly as before and no call can fail for lack of a
// network. The composer chip of an offered-but-offline tool shows `net.offlineShort` (ComposerMenuItem.State.offline).
// Availability gating only: it reads the network state and never the content of anything (R-241).
import AntiChatEngineProtocol
import AntiChatNetwork
import AntiChatTools
import Foundation

public struct OnlineToolGate: Sendable {
    public enum Kind: String, Sendable, Hashable { case local, web, mcp, relay }

    public let policy: NetworkPolicyStore
    public let path: PathStatus
    /// Which online kind a tool is (default: the web tools and the app's MCP tool set).
    public let kind: @Sendable (_ name: String) -> Kind

    public init(policy: NetworkPolicyStore = .shared, path: PathStatus = .shared,
                kind: (@Sendable (_ name: String) -> Kind)? = nil) {
        self.policy = policy
        self.path = path
        self.kind = kind ?? { Self.kind(of: $0, mcp: MCPTools.shared) }
    }

    /// A tool's kind: a web tool, an MCP tool of `mcp` (Composio = relay), else local.
    public static func kind(of name: String, mcp: MCPTools.ToolSet) -> Kind {
        if WebSearchTools.names.contains(name) { return .web }
        if let d = mcp.descriptor(named: name) { return d.composio ? .relay : .mcp }
        return .local
    }

    /// Whether tools of `kind` can work now.
    public func isAvailable(_ kind: Kind) -> Bool {
        switch kind {
        case .local: true
        case .web: WebSearchAvailability(policy: policy, path: path).isAvailable
        case .mcp: policy.isEnabled(.mcp) && !path.isOffline
        case .relay: policy.isEnabled(.relay) && !path.isOffline
        }
    }

    public func allows(_ name: String) -> Bool { isAvailable(kind(name)) }

    /// `tools` without the online ones that cannot work now (order kept).
    public func filter(_ tools: [ToolSchema]) -> [ToolSchema] { tools.filter { allows($0.name) } }
}
