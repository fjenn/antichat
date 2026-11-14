// M2.T05 (R-220 AC1, NFR-SEC7; E.2.6): the catalog's two user-visible states in Settings › Capabilities.
//   expired      → warn banner `catalog.expired` + [Check now]: installed models keep working.
//   badSignature → row `catalog.badSignature` + [Retry]: nothing new is installed until a good catalog arrives.
// Shows nothing while the catalog is fine (or before the store exists, e.g. in snapshot tests).
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct CatalogStatusBanner: View {
    let store: CatalogStore?
    @State private var status: CatalogStore.Status = .ok
    @State private var checking = false

    var body: some View {
        Group {
            if let key = CatalogStatusCopy.key(status) {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                        Image(systemName: status == .expired ? "exclamationmark.triangle" : "xmark.shield")
                            .foregroundStyle(Color.textSecondary)
                        Text(CopyKey(key))
                            .typeStyle(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            Task { checking = true; await store?.refresh(); checking = false; reload() }
                        } label: {
                            Text(CopyKey(status == .expired ? "set.updates.check" : "msg.retry"))
                        }
                        .disabled(checking)
                        .probeID("settings.cap.catalog.action")
                    }
                    .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                    .probeID("settings.cap.catalog.\(status.rawValue)")
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CatalogStore.didChange)) { _ in reload() }
    }

    private func reload() { status = store?.snapshot.status ?? .ok }
}
