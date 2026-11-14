// M10.T03 step 3 (R-219 AC2/AC4; components.md §1 StatusPill): "Restart to update" (`pill.update`, accent) in the
// sidebar footer once Sparkle has downloaded an update. Click → a small sheet with the release notes (the appcast
// item description, rendered offline as attributed text, no web view, no network) + [Restart to update]
// (`update.restart`) + [Later] (`update.later`). Quitting installs it anyway (SUAutomaticallyUpdate).
// fix/review P1: an update found but not downloaded (automatic downloads off) shows "Update available"
// (`pill.updateAvailable`) and [Download and install] (`update.download`), never a restart with nothing to install.
import AntiChatDesign
import AntiChatKnowledge
import AntiChatPlatform
import SwiftUI

struct UpdatePill: View {
    private let service: UpdaterService
    @State private var showingNotes = false

    init(service: UpdaterService = .shared) { self.service = service }

    var body: some View {
        if service.state.showsPill {
            Button { showingNotes = true } label: {
                Label {
                    Text(service.state.needsDownload ? CopyKey("pill.updateAvailable") : CopyKey("pill.update")).typeStyle(.caption)
                } icon: { Image(systemName: "arrow.down.app") }
                    .foregroundStyle(Color.accent)
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.surfaceHover))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.space2)
            .padding(.bottom, Spacing.space1)
            .accessibilityIdentifier("updatePill")
            .sheet(isPresented: $showingNotes) {
                UpdateNotesSheet(version: service.state.pillVersion ?? "",
                                 notes: service.state.pillNotesHTML,
                                 needsDownload: service.state.needsDownload,
                                 restart: { showingNotes = false; service.restartToUpdate() },
                                 later: { showingNotes = false })
            }
        }
    }
}

struct UpdateNotesSheet: View {
    let version: String
    let notes: String?
    /// Not downloaded yet: [Download and install] instead of [Restart to update].
    var needsDownload = false
    let restart: () -> Void
    let later: () -> Void

    /// Release notes HTML → text. RC review P2-7: never AppKit's HTML importer (it runs WebKit, which can fetch
    /// absolute `<img src>`, stylesheets and CSS `url()` outside NetworkGate). `HTMLText` parses the bytes with
    /// libxml2 (`HTML_PARSE_NONET`, no base URL), never reads an attribute and drops script/style, so no URL in the
    /// feed is resolved and nothing runs. Its Markdown is shown as inline-styled text with every link removed.
    static func render(_ html: String?) -> AttributedString? {
        guard let html, !html.isEmpty else { return nil }
        let text = HTMLText.markdown(Data(html.utf8))
        guard !text.isEmpty else { return nil }
        var out = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in out.runs where run.link != nil || run.imageURL != nil {
            out[run.range].link = nil
            out[run.range].imageURL = nil
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyText(needsDownload ? CopyKey("update.notes.available") : CopyKey("update.notes.title"), ["version": version]))
                .typeStyle(.title3)
            ScrollView {
                Text(Self.render(notes) ?? AttributedString(""))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 280)
            HStack {
                Spacer()
                Button(action: later) { Text(CopyKey("update.later")) }
                    .accessibilityIdentifier("update.later")
                    .keyboardShortcut(.cancelAction)
                Button(action: restart) { Text(needsDownload ? CopyKey("update.download") : CopyKey("update.restart")) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("update.restart")
            }
        }
        .padding(Spacing.space4)
        .frame(width: 440)
    }
}
