// Settings → Connections → [Add] (R-081 AC1, R-257): one sheet that adds a tool the list does not have, by its server
// address (a direct connection; the one place that says "MCP", in small grey). Step 1 is the form: what this is for
// in one sentence, Name and Address with their labels, and — only when the tool needs it — how to sign in ("This tool
// needs a sign-in" opens the choice: in the browser, or a key to paste; a server that refuses a check without a
// sign-in opens it by itself and says so). What is wrong shows under the field it is about, in plain words. [Continue]
// checks the server (ConnectionsModel.check, a dry `tools/list`); step 2, in the same sheet, is MCPConsentSheet: what
// the connection will be able to do, [Allow and connect]. Nothing is stored before that.
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct AddConnectionSheet: View {
    struct Form: Equatable {
        var name = ""
        var url = ""
        /// The sign-in choices are showing (false = a tool that needs no sign-in).
        var signIn = false
        var mode = Mode.browser
        var token = ""
        var clientID = ""
        enum Mode: Hashable { case browser, key }

        var auth: MCPAuthInput {
            guard signIn else { return .none }
            switch mode {
            case .browser: return clientID.isEmpty ? .oauth : .oauthClientID(clientID)
            case .key: return .token(token.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var address: URL? { ConnectionsModel.address(url) }
        /// Something is typed and it is not a web address.
        var addressIsWrong: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && address == nil }
        var isComplete: Bool { address != nil && (!signIn || mode == .browser || !auth.isEmptyToken) }
    }

    @Bindable var model: ConnectionsModel
    /// Allow on the consent step: the caller adds `pending` and closes the sheet.
    let onAllow: (ConnectionsModel.Pending) -> Void
    let onCancel: () -> Void
    @State var form: Form
    /// The consent step, kept while the sheet closes (the model's `pending` is cleared before it is gone).
    @State private var consent: ConnectionsModel.Pending?

    /// `form`: a filled-in form to draw (snapshots).
    init(model: ConnectionsModel, form: Form = Form(), onAllow: @escaping (ConnectionsModel.Pending) -> Void,
         onCancel: @escaping () -> Void) {
        self.model = model
        self.onAllow = onAllow
        self.onCancel = onCancel
        _form = State(initialValue: form)
    }

    /// The help centre's page on connections (nil without a site: no link).
    static var helpURL: URL? { SiteLinks.url("/help/connections/#add-a-custom-connection") }

    var body: some View {
        Group {
            if let p = consent ?? model.pending {
                MCPConsentSheet(pending: p, onAllow: { onAllow(p) }, onCancel: onCancel)
            } else {
                formStep
            }
        }
        .onChange(of: model.pending) { _, new in if let new { consent = new } }
        .onChange(of: model.needsAuth) { _, needs in if needs { form.signIn = true } }
    }

    private var signInShown: Bool { form.signIn || model.needsAuth }

    private var formStep: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text(CopyKey("conn.mcp.add")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(CopyKey("conn.mcp.lead")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Spacing.space4) {
                FormField(label: CopyKey("conn.mcp.name"), prompt: CopyKey("conn.mcp.name.example").string(), text: $form.name,
                          id: "connections.name")
                FormField(label: CopyKey("conn.mcp.url"), prompt: "https://example.com/mcp", text: $form.url, id: "connections.url",
                          note: form.addressIsWrong ? (CopyKey("conn.mcp.url.invalid"), .danger, "connections.url.invalid")
                              : (CopyKey("conn.mcp.url.note"), .textSecondary, "connections.url.note"))
                signIn
            }
            if let e = model.checkError {
                Label { Text(CopyText(CopyKey("conn.mcp.failed"), ["reason": e])).fixedSize(horizontal: false, vertical: true) }
                    icon: { Image(systemName: "exclamationmark.circle") }
                    .typeStyle(.footnote).foregroundStyle(Color.danger)
                    .probeID("connections.checkError")
            }
            HStack(spacing: Spacing.space3) {
                if let help = Self.helpURL {
                    Button { SiteLinks.open(help) } label: {
                        Text(CopyKey("conn.mcp.help")).typeStyle(.subhead).foregroundStyle(Color.textSecondary).underline()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .probeID("connections.help")
                }
                Spacer()
                if model.checking {
                    ProgressView().controlSize(.small)
                    Text(CopyKey("conn.mcp.checking")).typeStyle(.subhead).foregroundStyle(Color.textSecondary).lineLimit(1)
                }
                Button(action: onCancel) { Text(CopyKey("conn.mcp.cancel")) }.keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .probeID("connections.cancel")
                Button {
                    Task { await model.check(name: form.name, url: form.url, auth: form.auth) }
                } label: { Text(CopyKey("conn.mcp.next")) }
                .keyboardShortcut(.defaultAction).buttonStyle(.primary).controlSize(.large)
                .disabled(!form.isComplete || model.checking)
                .probeID("connections.check")
            }
        }
        .padding(Spacing.space6)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .probeID("connections.addSheet")
    }

    /// Closed: one quiet line. Open: how to sign in, and the key's field when a key is the way.
    @ViewBuilder private var signIn: some View {
        if signInShown {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack {
                    Text(CopyKey("conn.mcp.signIn")).typeStyle(.subhead).fontWeight(.medium).foregroundStyle(Color.textPrimary)
                    Spacer()
                    Button { form.signIn = false; model.resetCheck() } label: {
                        Text(CopyKey("conn.mcp.signIn.none")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .probeID("connections.auth.hide")
                }
                if model.needsAuth {
                    Text(CopyKey("conn.mcp.signIn.needed")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .probeID("connections.auth.needed")
                }
                HStack(spacing: Spacing.space1) {
                    mode(.browser, CopyKey("conn.mcp.oauth"), id: "connections.auth.browser")
                    mode(.key, CopyKey("conn.mcp.token"), id: "connections.auth.key")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: Radius.sm + 2, style: .continuous).fill(Color.surfaceSunken))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(CopyKey("conn.mcp.signIn")))
                .probeID("connections.authMode")
                if form.mode == .key {
                    FormField(label: nil, prompt: CopyKey("conn.mcp.token.prompt").string(), text: $form.token,
                              id: "connections.token", secure: true)
                } else if model.needsClientID {  // R-257: CIMD and DCR both unavailable at this server
                    FormField(label: nil, prompt: CopyKey("conn.mcp.clientId").string(), text: $form.clientID,
                              id: "connections.clientId")
                }
            }
        } else {
            Button { form.signIn = true } label: {
                HStack(spacing: Spacing.space1) {
                    Text(CopyKey("conn.mcp.signIn.show")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.textTertiary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .probeID("connections.auth.show")
        }
    }
}

private extension AddConnectionSheet {
    /// One half of the two-way choice: the chosen half is a raised tile.
    func mode(_ m: Form.Mode, _ title: CopyKey, id: String) -> some View {
        let on = form.mode == m
        return Button { form.mode = m } label: {
            Text(title).typeStyle(.subhead).fontWeight(on ? .medium : .regular)
                .foregroundStyle(on ? Color.textPrimary : Color.textSecondary).lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(on ? Color.surfaceCanvas : .clear)
                    .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1.5, y: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .probeID(id)
    }
}

private extension MCPAuthInput {
    var isEmptyToken: Bool { if case .token(let t) = self { t.isEmpty } else { false } }
}

/// A labelled field of the sheet: the label above, the prompt inside, one line under it (a hint in grey, or what is
/// wrong in red).
private struct FormField: View {
    let label: CopyKey?
    let prompt: String
    @Binding var text: String
    let id: String
    var secure = false
    var note: (text: CopyKey, color: Color, id: String)?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1 + 2) {
            if let label {
                Text(label).typeStyle(.subhead).fontWeight(.medium).foregroundStyle(Color.textPrimary)
            }
            Group {
                if secure {
                    SecureField(text: $text, prompt: Text(verbatim: prompt).foregroundStyle(Color.textTertiary)) { Text(verbatim: label?.string() ?? prompt) }
                } else {
                    TextField(text: $text, prompt: Text(verbatim: prompt).foregroundStyle(Color.textTertiary)) { Text(verbatim: label?.string() ?? prompt) }
                }
            }
            .textFieldStyle(.plain)
            .typeStyle(.callout)
            .focused($focused)
            .probeID(id)
            .padding(.horizontal, Spacing.space3)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Radius.sm + 2, style: .continuous).fill(Color.surfaceSunken))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm + 2, style: .continuous)
                .strokeBorder(note?.color == .danger ? Color.danger : focused ? Color.textPrimary.opacity(0.35) : .clear, lineWidth: 1))
            if let note {
                Text(note.text).typeStyle(.footnote).foregroundStyle(note.color).fixedSize(horizontal: false, vertical: true)
                    .probeID(note.id)
            }
        }
    }
}
