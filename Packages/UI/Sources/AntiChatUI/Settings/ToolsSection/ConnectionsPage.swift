// M7.T06 step 4 (R-081 AC1/AC4; S-21 §7 → Connections, `conn.title`): the user's connections (none until they add
// one; nothing connects before), [Add an MCP server] (URL, name, No sign-in / Paste a token / Sign in with the app —
// M7.T07 OAuth; `conn.mcp.clientId` appears only after CIMD and DCR were both unavailable), the
// Popular connections directory, the Composio app tiles (M7.T11) and the local-servers note (M11).
import AntiChatDesign
import AntiChatFoundation
import AntiChatTools
import SwiftUI

struct ConnectionsPage: View {
    @State private var model = ConnectionsModel()
    @State private var selected: String?
    @State private var adding = false
    @State private var form = AddForm()
    @Environment(\.openURL) private var openURL

    struct AddForm: Equatable {
        var name = ""
        var url = ""
        var mode = Mode.none
        var token = ""
        var clientID = ""
        var curatedID: String?
        enum Mode: Hashable { case none, token, oauth }
        var useToken: Bool { mode == .token }

        var auth: MCPAuthInput {
            switch mode {
            case .none: .none
            case .token: .token(token)
            case .oauth: clientID.isEmpty ? .oauth : .oauthClientID(clientID)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.servers.isEmpty {
                Text(CopyKey("conn.empty")).font(.callout).foregroundStyle(Color.textSecondary).probeID("connections.empty")
            }
            ForEach(model.servers) { s in
                VStack(alignment: .leading, spacing: 0) {
                    ConnectionRow(server: s).onTapGesture { selected = selected == s.id ? nil : s.id }
                        .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space expands the row
                        .accessibilityAction { selected = selected == s.id ? nil : s.id }
                    if selected == s.id { ConnectionDetail(model: model, server: s) }
                }
            }
            // An add that failed after Allow (the sheet is closed by then): say why here (P6 only logged it).
            if !adding, let e = model.checkError {
                Text(CopyText(CopyKey("conn.mcp.failed"), ["reason": e])).font(.caption).foregroundStyle(.red)
                    .probeID("connections.error")
            }
            Button { form = AddForm(); model.checkError = nil; adding = true } label: { Label { Text(CopyKey("conn.mcp.add")) } icon: { Image(systemName: "plus") } }
                .probeID("connections.add")
            Divider().padding(.vertical, Spacing.space1)  // VQ (M10): the three blocks read as separate groups
            if model.composioAvailable {  // hidden only without a deployed relay (RelayClient.isAvailable)
                composioSection
                Divider().padding(.vertical, Spacing.space1)
            }
            MCPDirectoryView(entries: model.curated) { e in
                form = AddForm(name: e.name, url: e.url, mode: e.auth == "token" ? .token : e.auth == "oauth" ? .oauth : .none, curatedID: e.id)
                adding = true
            }
        }
        .sheet(isPresented: $adding) { addSheet }
        .sheet(item: $model.composioConsent) { item in
            ComposioConsentSheet(toolkit: item.toolkit, onContinue: { Task { await model.beginComposio(item.toolkit) } },
                                 onCancel: {})
        }
        .task {
            // The sign-in page goes to the browser, or (DEBUG `-OpenURLSpy`, ComposioUITests / MCPOAuthUITests) to the
            // spy file, where the test plays the browser.
            model.openURL = { url in
                if LaunchOptions.current.openURLSpy != nil { SiteLinks.open(url) } else { openURL(url) }
            }
            await model.refreshComposio()
        }
        .sheet(item: $model.pending) { p in
            MCPConsentSheet(pending: p, onAllow: { Task { await model.confirm(p) } }, onCancel: { Task { await model.decline() } })
        }
    }

    /// VQ (S-21 Tools): an app with its own entry under Popular connections (a direct connection, no cloud bridge) is
    /// not offered a second time as a Composio tile, unless it is already linked through Composio.
    private var composioShown: [String] {
        let direct = Set(model.curated.map { $0.name.lowercased() })
        return model.composioTiles.filter { model.composioLinked[$0] != nil || !direct.contains(ComposioTiles.title($0).lowercased()) }
    }

    /// M7.T11 (R-255 AC3): the Composio apps — one tile per toolkit with [Connect] / Connected · [Disconnect].
    private var composioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: "Composio").font(.headline)
                CloudBadge()
            }
            Text(CopyKey("conn.composio.intro")).typeStyle(.caption).foregroundStyle(Color.textSecondary)
            // VQ (S-21 Tools, M10): two roomy tiles per row (four 150 pt tiles wrapped "Google Calendar" and crowded
            // the card); a name stays on one line.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: Spacing.space2, alignment: .leading)],
                      alignment: .leading, spacing: Spacing.space2) {
                ForEach(composioShown, id: \.self) { t in
                    HStack(spacing: Spacing.space2) {
                        Text(verbatim: ComposioTiles.title(t)).typeStyle(.callout).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: Spacing.space2)
                        if model.composioLinked[t] != nil {
                            Button { Task { await model.disconnectTile(t) } } label: { Text(CopyKey("conn.disconnect")) }
                                .buttonStyle(.link).probeID("composio.disconnect.\(t)")
                        } else if model.composioWaiting == t {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { model.connectTile(t) } label: { Text(CopyKey("conn.connect")) }
                                .buttonStyle(.link).probeID("composio.connect.\(t)")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.surfaceSunken))  // as the directory cards
                }
            }
            // M9.T03: a lazy grid is an unnamed "Other" to accessibility; the tiles sit in a named group.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "Composio"))
            if let e = model.composioError {
                Text(CopyKey(e)).font(.caption).foregroundStyle(.orange).probeID("composio.error")
            }
        }
        .accessibilityElement(children: .contain)  // keeps composio.connect.* (Q-015 catch-up)
        .probeID("connections.composio")
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CopyKey("conn.mcp.add")).font(.headline)
            TextField(text: $form.url) { Text(CopyKey("conn.mcp.url")) }.textFieldStyle(.roundedBorder).probeID("connections.url")
            TextField(text: $form.name) { Text(CopyKey("conn.mcp.name")) }.textFieldStyle(.roundedBorder).probeID("connections.name")
            Picker(selection: $form.mode) {
                Text(CopyKey("conn.mcp.noAuth")).tag(AddForm.Mode.none)
                Text(CopyKey("conn.mcp.token")).tag(AddForm.Mode.token)
                Text(CopyKey("conn.mcp.oauth")).tag(AddForm.Mode.oauth)
            } label: { EmptyView() }.pickerStyle(.segmented).accentFilledSegments().labelsHidden().probeID("connections.authMode")
            if form.useToken {
                SecureField(text: $form.token) { Text(CopyKey("conn.mcp.token")) }.textFieldStyle(.roundedBorder).probeID("connections.token")
            }
            if form.mode == .oauth, model.needsClientID {  // R-257: CIMD and DCR both unavailable at this server
                TextField(text: $form.clientID) { Text(CopyKey("conn.mcp.clientId")) }.textFieldStyle(.roundedBorder).probeID("connections.clientId")
            }
            if model.checking { Text(CopyKey("conn.mcp.checking")).typeStyle(.caption).foregroundStyle(Color.textSecondary) }
            if let e = model.checkError { Text(CopyText(CopyKey("conn.mcp.failed"), ["reason": e])).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button { adding = false } label: { Text(CopyKey("conn.mcp.cancel")) }.keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await model.check(name: form.name, url: form.url, auth: form.auth, curatedID: form.curatedID)
                        if model.pending != nil { adding = false }
                    }
                } label: { Text(CopyKey("conn.mcp.next")) }
                .keyboardShortcut(.defaultAction)
                .disabled(form.url.isEmpty || model.checking || (form.useToken && form.token.isEmpty))
                .probeID("connections.check")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
