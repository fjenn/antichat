// M2.T02 step 5 (R-297, P-platform-08): the package hooks for the networking dependencies of AntiChatTools.
// swift-sdk's HTTP transport and EventSource build their own URLSession; both get the gate's session or
// configuration here, so their requests carry the `mcp` category (InjectionCoverageTests checks this file).
import Foundation
import AntiChatNetwork
import EventSource
import MCP

public enum GatedTransports {
    /// MCP over Streamable HTTP (M7 G-031 connects through this; its configuration is the gate's).
    public static func mcpHTTP(endpoint: URL, category: NetworkCategory = .mcp) -> HTTPClientTransport {
        HTTPClientTransport(endpoint: endpoint, configuration: NetworkGate.configuration(for: category))
    }

    /// An SSE stream through the gate.
    public static func eventSource(request: URLRequest, category: NetworkCategory) -> EventSource {
        EventSource(request: NetworkGate.tag(request, category: category), configuration: NetworkGate.configuration(for: category))
    }
}
