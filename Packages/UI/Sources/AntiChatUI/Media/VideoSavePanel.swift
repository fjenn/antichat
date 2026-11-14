// M5.T12 step 3 (R-045 AC2, R-287 AC2): Export MP4 / Save As… of a stored clip asks where (`NSSavePanel`, `.mp4`) with one
// checkbox under the panel: `img.saveWithoutDetails` ("Save without prompt details", default off, the same accessory as
// the picture save of M4.T09). Checked, MediaProvenanceWriter.exportMP4 re-muxes the clip without the prompt and keeps the AI mark.
// UI tests: `-SaveVideoFile <path>` stands in for the panel and `-SaveVideoWithoutDetails` ticks the box (XCUITest cannot
// drive NSSavePanel reliably; Debug builds only).
import AntiChatDesign
import AntiChatFoundation
import AntiChatTools
import AppKit
import UniformTypeIdentifiers

/// The destination of a clip save and whether the prompt details stay out.
public struct VideoSaveChoice: Sendable, Equatable {
    public var url: URL
    public var stripPrompt: Bool
    public init(url: URL, stripPrompt: Bool) { self.url = url; self.stripPrompt = stripPrompt }
}

@MainActor
enum VideoSavePanel {
    /// The checkbox placed under the save panel (default off).
    static func checkbox() -> NSButton {
        let box = NSButton(checkboxWithTitle: CopyKey("img.saveWithoutDetails").string(), target: nil, action: nil)
        box.state = .off
        box.setAccessibilityIdentifier("savePanel.withoutDetails")
        box.sizeToFit()
        box.frame.origin = NSPoint(x: 20, y: 8)
        return box
    }

    /// "video.mp4" → a name that ends in `.mp4`.
    static func suggestedName(_ name: String?) -> String {
        let base = ((name ?? "") as NSString).deletingPathExtension
        return (base.isEmpty ? "Video" : base) + ".mp4"
    }

    /// Asks for the destination (nil when cancelled).
    static func choose(suggestedName: String) async -> VideoSaveChoice? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-SaveVideoFile"), i + 1 < args.count {
            return VideoSaveChoice(url: URL(fileURLWithPath: args[i + 1]), stripPrompt: args.contains("-SaveVideoWithoutDetails"))
        }
        #endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let box = checkbox()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: box.frame.maxX + 20, height: box.frame.height + 16))
        container.addSubview(box)
        panel.accessoryView = container
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        return VideoSaveChoice(url: url, stripPrompt: box.state == .on)
    }

    /// Export MP4: asks, then writes (nil when cancelled or the write failed).
    @discardableResult
    static func export(_ source: URL, name: String?) async -> URL? {
        guard let choice = await choose(suggestedName: suggestedName(name)) else { return nil }
        return await write(source, to: choice)
    }

    /// Writes the chosen copy; a failure shows the error toast (nil).
    static func write(_ source: URL, to choice: VideoSaveChoice) async -> URL? {
        do {
            try await MediaProvenanceWriter.exportMP4(source, to: choice.url, stripPrompt: choice.stripPrompt)
            return choice.url
        } catch {
            // M5 review P2-7: an error toast (the toast host also posts it as a VoiceOver announcement), not a beep.
            AppLog.log(.ui, .error, "video export failed: \(error)")
            AppToasts.shared.show(Toast(.warning, CopyText(CopyKey("video.exportFailed"))))
            return nil
        }
    }
}
