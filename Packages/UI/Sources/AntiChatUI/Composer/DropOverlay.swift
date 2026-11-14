// M6.T01 step 7 (S-14 drag-over; IS-6): dragging files over the chat column shows a full-column overlay with
// `files.drop`; dropping hands the file URLs (and dropped images / raw data, written to a temp file first) to the
// composer's intake. Applied by MainWindow on the chat column when the window supplies `MainWindowSlots.dropFiles`.
import AntiChatDesign
import SwiftUI
import UniformTypeIdentifiers

struct DropOverlay: ViewModifier {
    let onFiles: @MainActor ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image, .data], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    let urls = await PasteHandler.fileURLs(from: providers)
                    if !urls.isEmpty { onFiles(urls) }
                }
                return true
            }
            .overlay {
                if targeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                            .fill(Color.surfaceCanvas.opacity(0.92))
                        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        VStack(spacing: Spacing.space2) {
                            Image(systemName: "doc.badge.plus").font(.system(size: 32)).foregroundStyle(Color.textSecondary)
                            Text(CopyKey("files.drop")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
                        }
                    }
                    .padding(Spacing.space4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                    .probeID("dropOverlay")
                }
            }
    }
}

extension View {
    /// Whole-column file drop (M6.T01); nil = no drop target.
    @ViewBuilder func fileDropOverlay(_ onFiles: (@MainActor ([URL]) -> Void)?) -> some View {
        if let onFiles { modifier(DropOverlay(onFiles: onFiles)) } else { self }
    }
}
