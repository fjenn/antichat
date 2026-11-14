// M6.T10 step 5 (R-273 AC4): the FileCard of a revised file with the ‹ v1 v2 › switcher (`msg.version` style: chevrons
// around "Version {n}" = `file.version`). Opens on the newest version; an older one stays openable, Quick Look-able,
// Save As-able and draggable (its blob is never replaced). The chain comes from the tool result (persisted), so a
// reloaded chat shows the same switcher.
import AntiChatDesign
import AntiChatTools
import SwiftUI

public struct FileCardVersionSwitcher: View {
    let latest: FileCardItem
    let versions: [VersionInfo]
    @State private var model: FileCardViewModel
    @State private var index: Int

    public init(latest: FileCardItem, versions: [VersionInfo]) {
        self.latest = latest
        self.versions = versions.sorted { $0.n < $1.n }
        let last = max(self.versions.count - 1, 0)
        _index = State(initialValue: last)
        _model = State(initialValue: FileCardViewModel(item: Self.item(latest, self.versions, last)))
    }

    static func item(_ latest: FileCardItem, _ versions: [VersionInfo], _ i: Int) -> FileCardItem {
        guard versions.indices.contains(i) else { return latest }
        let v = versions[i]
        return FileCardItem(url: URL(fileURLWithPath: v.path), displayName: latest.displayName, contentType: latest.contentType,
                            size: v.size, version: v.n)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            FileCard(model: model, showsThumbnail: true)
            HStack(spacing: Spacing.space1) {
                Button { select(index - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .accessibilityLabel(Text(CopyKey("a11y.version.previous")))
                    .accessibilityIdentifier("fileVersionPrevious")
                Text(CopyText(CopyKey("file.version"), ["n": String(versions.indices.contains(index) ? versions[index].n : 1)]))
                    .typeStyle(.caption).foregroundStyle(Color.textSecondary).monospacedDigit()
                    .accessibilityIdentifier("fileVersionLabel")
                Button { select(index + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= versions.count - 1)
                    .accessibilityLabel(Text(CopyKey("a11y.version.next")))
                    .accessibilityIdentifier("fileVersionNext")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fileVersionSwitcher")
        }
    }

    func select(_ i: Int) {
        guard versions.indices.contains(i), i != index else { return }
        index = i
        model.item = Self.item(latest, versions, i)
    }
}
