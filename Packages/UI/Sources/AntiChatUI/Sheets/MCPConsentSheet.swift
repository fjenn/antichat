// M7.T06 step 5 (R-081, NFR-SEC4; S-24 MCP consent): before the first connect, the sheet names the server, its URL,
// the tools the dry `tools/list` found (each with Reads only / Can change things) and the permission rule
// (`conn.mcp.consent.lead`). Cancel stores nothing and tears the dry session down (ConnectionsModel.decline).
// VQ-M11 S-24: a question as the title ("Connect to Team chat?", the server's own name when none was typed instead of
// the bare host), the URL as a secondary line, each tool by its readable name (the server's title, else the id in
// words; the raw id stays in the tooltip) with its description, and type-scale text instead of tiny captions.
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct MCPConsentSheet: View {
    let pending: ConnectionsModel.Pending
    var onAllow: () -> Void
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    /// The name people read: the typed name; when none was typed (the name is the host), the server's own name.
    static func displayName(_ p: ConnectionsModel.Pending) -> String {
        let info = p.preview.serverInfo.split(separator: " ").first.map(String.init) ?? ""
        guard p.name == p.url.host(), !info.isEmpty, info != p.url.host() else { return p.name }
        return toolName(info)
    }

    /// The server's title for a tool, else its id in words (`send_message` → "Send message").
    static func toolName(_ t: MCPListedTool) -> String {
        if let title = t.annotations.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return toolName(t.name)
    }

    static func toolName(_ id: String) -> String {
        let words = id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return id }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    var body: some View {
        let name = Self.displayName(pending)
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(alignment: .center, spacing: Spacing.space3) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 20, weight: .regular)).foregroundStyle(Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.textPrimary.opacity(0.06)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CopyText(CopyKey("conn.mcp.consent.title"), ["server": name]))
                        .typeStyle(.title3).foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .probeID("mcpConsent.title")
                    Text(verbatim: pending.url.absoluteString).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            Text(CopyText(CopyKey("conn.mcp.consent.lead"), ["server": name]))
                .typeStyle(.callout).foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(pending.preview.tools.enumerated()), id: \.element.name) { i, t in
                        if i > 0 { Divider().padding(.leading, Spacing.space3) }
                        toolRow(t)
                    }
                }
            }
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.textPrimary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.textPrimary.opacity(0.08)))
            HStack {
                Spacer()
                Button { onCancel(); dismiss() } label: { Text(CopyKey("conn.mcp.cancel")) }.keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .probeID("mcpConsent.cancel")
                Button { onAllow(); dismiss() } label: { Text(CopyKey("conn.mcp.allow")) }.keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .probeID("mcpConsent.allow")
            }
        }
        .padding(Spacing.space6)
        .frame(width: 480)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("mcpConsent")
    }

    @ViewBuilder private func toolRow(_ t: MCPListedTool) -> some View {
        let write = t.annotations.isWriteType(toolName: t.name)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.toolName(t)).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                if !t.description.isEmpty {
                    Text(verbatim: t.description).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.space3)
            Label { Text(CopyKey(write ? "conn.canChange" : "conn.readsOnly")) } icon: {
                Image(systemName: write ? "pencil" : "eye")
            }
            .typeStyle(.footnote)
            .foregroundStyle(write ? Color.warning : Color.textSecondary)
            .fixedSize()
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .help(t.name)  // the server's own id, for people who look it up
        .accessibilityElement(children: .combine)
    }
}
