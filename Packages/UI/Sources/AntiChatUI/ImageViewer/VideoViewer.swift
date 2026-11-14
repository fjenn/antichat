// M5.T12 step 2 (R-045 AC1, R-040 AC3 "opens in the viewer with Save As…"; S-13): the full-window clip viewer, an overlay
// over the chat column (or the Library). The same player as the card (inline AVPlayerView controls: play/pause, scrub,
// full screen; loop and mute), plus Save As… (`file.saveAs`, with "Save without prompt details") and Show in Finder
// (`library.reveal`). Esc or Close returns to where it was opened (the view under the overlay never moves).
import AntiChatDesign
import AppKit
import SwiftUI

/// What the viewer plays: a stored, gated clip.
public struct VideoViewerTarget: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    /// The name Save As suggests (artifact title / attachment name).
    public var name: String?
    public init(path: String, name: String? = nil) { self.path = path; self.name = name }
}

/// Opens the viewer (ConversationView and LibraryView provide it; nil elsewhere).
public struct VideoViewerOpener: @unchecked Sendable {
    let open: @MainActor (VideoViewerTarget) -> Void
    public init(_ open: @escaping @MainActor (VideoViewerTarget) -> Void) { self.open = open }
    @MainActor public func callAsFunction(_ t: VideoViewerTarget) { open(t) }
}

extension EnvironmentValues {
    @Entry public var openVideoViewer: VideoViewerOpener?
}

public struct VideoViewer: View {
    let target: VideoViewerTarget
    let onClose: () -> Void
    @State private var model: InlineVideoPlayerModel

    public init(target: VideoViewerTarget, onClose: @escaping () -> Void) {
        self.target = target
        self.onClose = onClose
        _model = State(initialValue: InlineVideoPlayerModel(url: URL(fileURLWithPath: target.path)))
    }

    public var body: some View {
        ZStack {
            Color.surfaceCanvas.opacity(0.97).ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: Spacing.space3) {
                toolbar
                AVPlayerViewRepresentable(player: model.player)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(Spacing.space5)
        }
        .task {
            await model.load()
            if model.phase != .error { model.play() }
        }
        .onDisappear { model.pause() }
        .onExitCommand(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CopyKey("video.viewer.a11y")))
        .accessibilityIdentifier("videoViewer")
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.space2) {
            Toggle(isOn: Binding(get: { model.loops }, set: { model.setLoops($0) })) { Text(CopyKey("video.loop")) }
                .toggleStyle(.button)
                .accessibilityIdentifier("videoViewer.loop")
            Toggle(isOn: Binding(get: { model.isMuted }, set: { model.setMuted($0) })) { Text(CopyKey("video.mute")) }
                .toggleStyle(.button)
                .accessibilityIdentifier("videoViewer.mute")
            Spacer()
            Button { Task { await VideoSavePanel.export(URL(fileURLWithPath: target.path), name: target.name) } } label: {
                Text(CopyKey("file.saveAs"))
            }
            .accessibilityIdentifier("videoViewer.saveAs")
            if VideoJobCard.offersFinder(URL(fileURLWithPath: target.path)) {  // M5 review P2-5: no Finder for incognito
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)]) } label: {
                    Text(CopyKey("library.reveal"))
                }
                .accessibilityIdentifier("videoViewer.reveal")
            }
            Button(action: onClose) { Text(CopyKey("video.viewer.close")) }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("videoViewer.close")
        }
        .controlSize(.regular)
    }
}
