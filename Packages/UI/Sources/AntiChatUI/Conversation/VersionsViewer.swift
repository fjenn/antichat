// VersionsViewer (M1.T10 step 3; IS-11; ChatGPT FL-12 "Versions" modal): every version of a turn (the siblings,
// oldest first) with its timestamp; the selected one is shown in full (for a user version, its prompt and its
// reply), stepped with ‹ Version n ›. [Use this version] makes it the visible one (the branch below it comes
// back with it), [Return to current version] closes without a change, [Branch in new chat] copies the chat up to
// that version into a new chat.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct VersionsViewer: View {
    let versions: [MessageVersion]
    let onUse: (String) -> Void
    let onBranch: (String) -> Void
    let onClose: () -> Void

    @State private var selected: String?

    private var current: MessageVersion? {
        versions.first { $0.id == selected } ?? versions.first(where: \.isActive) ?? versions.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("msg.versions"))
                .typeStyle(.title3)
                .foregroundStyle(Color.textPrimary)
            HStack(alignment: .top, spacing: Spacing.space4) {
                list
                    .frame(width: 200)
                Divider()
                detail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 320)
            HStack(spacing: Spacing.space2) {
                // VQ-M10 S-09: on the current version there is nothing to return to and nothing to switch to: the
                // left button reads Close and "Use this version" is not shown (a disabled prominent button still read
                // as enabled in dark).
                let showingCurrent = current?.isActive ?? true
                Button(action: onClose) { Text(CopyKey(showingCurrent ? "panel.close" : "msg.versions.return")) }
                    .keyboardShortcut(.cancelAction)
                    .tint(.primary)  // VQ round 65: label-coloured, not low-contrast accent text on grey in dark
                    .accessibilityIdentifier("versionsViewer.returnToCurrent")
                Spacer()
                Button { if let v = current { onBranch(v.id) } } label: { Text(CopyKey("msg.branch")) }
                    .tint(.primary)
                    .accessibilityIdentifier("versionsViewer.branch")
                if !showingCurrent {
                    Button { if let v = current { onUse(v.id) } } label: { Text(CopyKey("msg.versions.use")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("versionsViewer.use")
                }
            }
        }
        .padding(Spacing.space5)
        .frame(width: 680)
        .background(Color.surfaceCanvas)
        .onAppear { selected = versions.first(where: \.isActive)?.id ?? versions.last?.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versionsViewer")
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                ForEach(versions) { v in
                    Button { selected = v.id } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Spacing.space1) {
                                Text(CopyText(CopyKey("msg.versions.item"), ["n": "\(v.index)"]))
                                    .typeStyle(.bodyEmph)
                                    .foregroundStyle(Color.textPrimary)
                                if v.isActive {
                                    Text(CopyKey("msg.versions.current"))
                                        .typeStyle(.caption)
                                        .foregroundStyle(Color.textSecondary)
                                        .accessibilityIdentifier("versionsViewer.current")
                                }
                            }
                            Text(verbatim: Self.timestamp(v, among: versions))
                                .typeStyle(.footnote)
                                .foregroundStyle(Color.textSecondary)
                            Text(verbatim: preview(v))
                                .typeStyle(.footnote)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.space2)
                        .background(v.id == current?.id ? Color.surfaceSelected : .clear,
                                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("versionsViewer.row.\(v.index)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versionsViewer.list")
    }

    @ViewBuilder private var detail: some View {
        if let v = current {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                VersionStepper(version: v) { delta in
                    let j = v.index - 1 + delta
                    if versions.indices.contains(j) { selected = versions[j].id }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space3) {
                        if v.role == .user {
                            Text(verbatim: v.text)
                                .typeStyle(.body)
                                .foregroundStyle(Color.textPrimary)
                                .padding(.horizontal, Spacing.space3)
                                .padding(.vertical, Spacing.space2)
                                .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            if let reply = v.replyText, !reply.isEmpty {
                                MessageMarkdownView(text: reply, streaming: false, interrupted: false, live: nil)
                            }
                        } else {
                            MessageMarkdownView(text: v.text, streaming: false, interrupted: v.status == .interrupted, live: nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("versionsViewer.detail")
                    .id(v.id)  // a fresh renderer per version (MessageMarkdownView keeps its text in @State)
                }
                // The shown version's text as one static text (UI tests compare it with the original).
                .background {
                    Color.clear
                        .accessibilityElement()
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(Text(verbatim: v.text))
                        .accessibilityIdentifier("versionsViewer.text")
                }
            }
        }
    }

    /// The version's time; with seconds when another version shows the same minute (VQ round 65, S-09: two versions a
    /// few seconds apart both read "Today at 8:55 PM"). Pure.
    static func timestamp(_ v: MessageVersion, among all: [MessageVersion]) -> String {
        let short = ActionBar.timestamp(v.createdAt)
        guard all.contains(where: { $0.id != v.id && ActionBar.timestamp($0.createdAt) == short }) else { return short }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        f.doesRelativeDateFormatting = true
        return f.string(from: v.createdAt)
    }

    private func preview(_ v: MessageVersion) -> String {
        let s = v.text.replacingOccurrences(of: "\n", with: " ")
        return s.count > 120 ? String(s.prefix(120)) + "…" : s
    }
}

/// "‹ Version n ›" over the viewer's detail (ChatGPT's modal header).
private struct VersionStepper: View {
    let version: MessageVersion
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Button { onStep(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .disabled(version.index <= 1)
                .accessibilityLabel(Text(CopyKey("msg.version.previous")))
                .accessibilityIdentifier("versionsViewer.previous")
            Text(CopyText(CopyKey("msg.versions.item"), ["n": "\(version.index)"]))
                .typeStyle(.bodyEmph)
                .monospacedDigit()
                .accessibilityIdentifier("versionsViewer.label")
            Button { onStep(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
                .disabled(version.index >= version.total)
                .accessibilityLabel(Text(CopyKey("msg.version.next")))
                .accessibilityIdentifier("versionsViewer.next")
        }
        .foregroundStyle(Color.textSecondary)
    }
}
