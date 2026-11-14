// M2.T03 step 4 (R-209 AC5): the globe chip under a reply that used the internet: `net.chip` ("Used the internet ·
// {count} sites"); its popover lists the hosts (`net.chip.hosts`). A reply without network use shows none.
import AntiChatDesign
import SwiftUI

struct NetworkChip: View {
    let hosts: [String]
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label { Text(CopyText(CopyKey("net.chip"), ["count": "\(hosts.count)"]).string).typeStyle(.caption) } icon: {
                Image(systemName: "globe")
            }
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.surfaceHover))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(CopyText(CopyKey("net.chip.hosts"), ["hosts": hosts.joined(separator: ", ")]).string)
                .typeStyle(.callout)
                .padding(Spacing.space3)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("networkChip.hosts")
        }
        .accessibilityIdentifier("networkChip")
        .accessibilityLabel(Text(CopyText(CopyKey("net.chip"), ["count": "\(hosts.count)"]).string))
    }
}
