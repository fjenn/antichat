// M7.T06 step 4 (R-081 AC2): the details of a connection the user added by address, as a sheet (`⋯` › Details and
// permissions, or a click on its row): its name and address, what needs the user now (sign in again, M7.T07; review
// what the server changed, M7.T08), "Use this connection", and what it can do — one line per tool with Reads only /
// Can change things (from the tool's annotations and name, ToolAnnotations.isWriteType) and when AntiChat may use it
// (Always allow / Ask / Block; Off takes the tool away from every chat). Remove is at the bottom left.
import AntiChatDesign
import AntiChatStorage
import AntiChatTools
import SwiftUI

struct ConnectionDetailSheet: View {
    @Bindable var model: ConnectionsModel
    /// The connection's id: the sheet follows the model's row (a removed connection closes it).
    let id: String
    let onClose: () -> Void
    @State private var reviewing: ToolChangeDiff?

    /// What the picker of a tool shows: one of the three permissions, or Off (the tool is not offered at all).
    enum Choice: Hashable { case always, ask, block, off }

    var body: some View {
        if let server = model.servers.first(where: { $0.id == id }) {
            content(server)
        } else {
            Color.clear.frame(width: 520, height: 1).onAppear(perform: onClose)
        }
    }

    private func content(_ server: ConnectionsModel.ServerView) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(spacing: Spacing.space3) {
                AppLogo(toolkit: nil, name: server.row.name, size: 26)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: server.row.name).typeStyle(.title3).foregroundStyle(Color.textPrimary).lineLimit(1)
                        .probeID("connection.title")
                    Text(verbatim: server.row.urlOrCmd).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            attention(server)
            Toggle(isOn: Binding(get: { server.row.enabled }, set: { on in Task { await model.setEnabled(server.id, on) } })) {
                Text(CopyKey("conn.enabled")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.accessibleSwitch)
            .probeID("connection.enabled")
            if !server.tools.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    Text(CopyKey("conn.tools")).typeStyle(.headline).foregroundStyle(Color.textPrimary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(server.tools.enumerated()), id: \.element.name) { i, t in
                                if i > 0 { Divider().padding(.leading, Spacing.space3) }
                                toolRow(t, server)
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.textPrimary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.textPrimary.opacity(0.08)))
                }
            }
            HStack(spacing: Spacing.space3) {
                Button(role: .destructive) { Task { await model.remove(server.id) }; onClose() } label: {
                    Text(CopyKey("conn.remove")).typeStyle(.callout).foregroundStyle(Color.danger).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .probeID("connection.remove")
                Spacer()
                Button(action: onClose) { Text(CopyKey("archived.done")) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.primary).controlSize(.large)
                    .probeID("connection.done")
            }
            .padding(.top, Spacing.space1)
        }
        .padding(Spacing.space6)
        .frame(width: 520)
        .accessibilityElement(children: .contain)
        .probeID("connection.detail")
        .sheet(item: Binding(get: { reviewing.map { DiffBox(diff: $0) } }, set: { reviewing = $0?.diff })) { box in
            ToolChangeReviewView(serverName: server.row.name, diff: box.diff) { model.accept(server.id) }
        }
    }

    /// One amber line and the button that settles it, when the connection needs the user.
    @ViewBuilder private func attention(_ server: ConnectionsModel.ServerView) -> some View {
        if server.row.state == .needsReauth {  // M7.T07 step 6: `mcp.authExpired` [Sign in again]
            notice(CopyText(CopyKey("mcp.authExpired"), ["app": server.row.name]), button: CopyKey("conn.reauth"), id: "connection.reauth") {
                Task { await model.signIn(server.id) }
            }
        } else if server.row.toolsChanged {  // M7.T08 (R-260): the side-by-side diff, then [Accept changes]
            notice(CopyText(CopyKey("mcp.toolsChanged"), ["server": server.row.name]), button: CopyKey("conn.review"), id: "connection.review") {
                reviewing = model.diff(server.id)
            }
        }
    }

    private func notice(_ text: CopyText, button: CopyKey, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.warning).accessibilityHidden(true)
            Text(text).typeStyle(.callout).foregroundStyle(Color.textPrimary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) { Text(button) }.probeID(id)
        }
        .padding(Spacing.space3)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.warning.opacity(0.10)))
    }

    struct DiffBox: Identifiable { let diff: ToolChangeDiff; var id: String { "\(diff.changed.map(\.name))\(diff.added)\(diff.removed)" } }

    private func choice(_ t: MCPToolRecord, _ server: ConnectionsModel.ServerView) -> Choice {
        guard t.enabled else { return .off }
        switch model.policy(t, server: server.row) {
        case .always: return .always
        case .ask: return .ask
        case .block: return .block
        }
    }

    private func set(_ c: Choice, _ t: MCPToolRecord, _ server: ConnectionsModel.ServerView) {
        let policy: ToolPermissionRecord.Policy? = switch c {
        case .always: .always
        case .ask: .ask
        case .block: .block
        case .off: nil
        }
        if t.enabled != (policy != nil) { model.setToolEnabled(server.id, t.name, policy != nil) }
        if let policy { model.setPolicy(policy, t) }
    }

    private func toolRow(_ t: MCPToolRecord, _ server: ConnectionsModel.ServerView) -> some View {
        let write = ToolAnnotations(json: t.annotationsJSON).isWriteType(toolName: t.name)
        let kind = CopyKey(write ? "conn.canChange" : "conn.readsOnly").string()
        return HStack(alignment: .center, spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: MCPConsentSheet.toolName(t.name)).typeStyle(.callout).foregroundStyle(Color.textPrimary).lineLimit(1)
                Text(verbatim: t.description.isEmpty ? kind : "\(kind) · \(t.description)")
                    .typeStyle(.footnote).foregroundStyle(Color.textSecondary).lineLimit(1).truncationMode(.tail)
                    .help(t.description)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(t.enabled ? 1 : 0.55)
            Picker(selection: Binding(get: { choice(t, server) }, set: { set($0, t, server) })) {
                Text(CopyKey("conn.perm.always")).tag(Choice.always)
                Text(CopyKey("conn.perm.ask")).tag(Choice.ask)
                Text(CopyKey("conn.perm.block")).tag(Choice.block)
                Divider()
                Text(CopyKey("conn.perm.off")).tag(Choice.off)
            } label: { Text(verbatim: MCPConsentSheet.toolName(t.name)) }
            .labelsHidden()
            .fixedSize()
            .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
            .probeID("connection.perm.\(t.name)")
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .help(t.name)  // the server's own id, for people who look it up
    }
}
