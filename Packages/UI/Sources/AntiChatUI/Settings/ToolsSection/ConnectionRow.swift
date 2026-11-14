// M7.T06 step 4 (R-081 AC1; S-21 §7): one connection: name, URL host, state (not connected · connecting · connected +
// tool count · needs re-auth · error · tools changed); the Composio row carries the `conn.cloud` badge (M7.T11).
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct ConnectionRow: View {
    let server: ConnectionsModel.ServerView

    var stateText: CopyText {
        let r = server.row
        if r.toolsChanged { return CopyText(CopyKey("conn.state.toolsChanged")) }
        switch r.state {
        case .notConnected: return CopyText(CopyKey("conn.state.notConnected"))
        case .connecting: return CopyText(CopyKey("conn.state.connecting"))
        case .connected: return CopyText(CopyKey("conn.state.connected"), ["count": "\(server.tools.count)"])
        case .needsReauth: return CopyText(CopyKey("mcp.authExpired"), ["app": r.name])
        case .error:
            // Q-015 r7: the relay's refusal says what it is ("Connections are busy. Try again in a minute.").
            if let code = r.errorCode, code.hasPrefix("relay."), CopyKey(code).isKnown { return CopyText(CopyKey(code)) }
            return CopyText(CopyKey("conn.state.error"))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(Color.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: server.row.name).font(.body)
                    if server.row.kind == .composio { CloudBadge() }  // M7.T11 (R-255 AC3)
                }
                // VQ (S-21 Tools, M10): a server named after its host ("chat.example") showed the host twice.
                let host = URL(string: server.row.urlOrCmd)?.host() ?? server.row.urlOrCmd
                if host.caseInsensitiveCompare(server.row.name) != .orderedSame {
                    Text(verbatim: host).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
            Text(stateText).font(.caption)
                .foregroundStyle(server.row.state == .error || server.row.state == .needsReauth || server.row.toolsChanged ? Color.orange : .secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("connectionRow.\(server.id)")
    }
}
