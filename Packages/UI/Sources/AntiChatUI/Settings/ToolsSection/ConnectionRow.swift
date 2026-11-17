// M7.T06 step 4 (R-081 AC1; S-21 §7): a connection the user added by address, as a row of the page's "Connected"
// section — the same row as an app (DirectoryRow): a tile with the name's initial, the name, one grey line (not
// connected · connecting · connected + tool count · needs sign-in · error · tools changed; amber when it needs the
// user) and `⋯`: Details and permissions (also a click on the row), Sign in again when the sign-in ran out, Remove.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct ConnectionRow: View {
    let server: ConnectionsModel.ServerView
    var pinnedHover: Bool?
    let onOpen: () -> Void
    let onSignIn: () -> Void
    let onRemove: () -> Void

    var stateText: CopyText {
        let r = server.row
        if r.toolsChanged { return CopyText(CopyKey("conn.state.toolsChanged")) }
        switch r.state {
        case .notConnected: return CopyText(CopyKey(r.enabled ? "conn.state.notConnected" : "conn.state.off"))
        case .connecting: return CopyText(CopyKey("conn.state.connecting"))
        case .connected: return CopyText(CopyKey("conn.state.connected"), ["count": "\(server.tools.count)"])
        case .needsReauth: return CopyText(CopyKey("mcp.authExpired"), ["app": r.name])
        case .error:
            // Q-015 r7: the relay's refusal says what it is ("Connections are busy. Try again in a minute.").
            if let code = r.errorCode, code.hasPrefix("relay."), CopyKey(code).isKnown { return CopyText(CopyKey(code)) }
            return CopyText(CopyKey("conn.state.error"))
        }
    }

    var needsAttention: Bool {
        server.row.state == .error || server.row.state == .needsReauth || server.row.toolsChanged
    }

    var body: some View {
        let name = server.row.name
        DirectoryRow(title: name, detail: stateText.string, detailColor: needsAttention ? .warning : .textSecondary,
                     detailID: "connection.state.\(server.id)", pinnedHover: pinnedHover) {
            AppLogo(toolkit: nil, name: name, size: 26)
        } trailing: {
            DirectoryMenu(label: "\(CopyKey("chat.more").string()), \(name)") { actions }
                .probeID("connections.menu.custom.\(server.id)")
        }
        .onTapGesture(perform: onOpen)
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space opens the details
        .accessibilityAction(.default, onOpen)
        .probeID("connectionRow.\(server.id)")
    }

    @ViewBuilder private var actions: some View {
        Button(action: onOpen) { Text(CopyKey("conn.details")) }.probeID("connection.details")
        if server.row.state == .needsReauth {
            Button(action: onSignIn) { Text(CopyKey("conn.reauth")) }.probeID("connection.reauth.menu")
        }
        Divider()
        Button(role: .destructive, action: onRemove) { Text(CopyKey("conn.remove")) }.probeID("connection.remove.menu")
    }
}
