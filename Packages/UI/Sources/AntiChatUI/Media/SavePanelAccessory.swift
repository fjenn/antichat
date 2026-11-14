// M4.T09 step 5 (R-287 AC2): Save / Save As… of a generated picture asks where, with one checkbox under the panel:
// `img.saveWithoutDetails` ("Save without prompt details", default off). Checked, the saved copy carries no prompt
// anywhere but keeps the AI mark, the creator tool and the model id (MediaProvenanceWriter.strippingPrompt).
// UI tests: `-SaveImageFile <path>` stands in for the panel and `-SaveImageWithoutDetails` ticks the box (XCUITest
// cannot drive NSSavePanel reliably; Debug builds only, as `-ExportFile`).
import AntiChatDesign
import AntiChatTools
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The destination of an image save and whether the prompt details stay out.
public struct ImageSaveChoice: Sendable, Equatable {
    public var url: URL
    public var stripPrompt: Bool
    public init(url: URL, stripPrompt: Bool) { self.url = url; self.stripPrompt = stripPrompt }
}

@MainActor
enum SavePanelAccessory {
    /// The checkbox placed under the save panel (default off).
    static func checkbox() -> NSButton {
        let box = NSButton(checkboxWithTitle: CopyKey("img.saveWithoutDetails").string(), target: nil, action: nil)
        box.state = .off
        box.setAccessibilityIdentifier("savePanel.withoutDetails")
        box.sizeToFit()
        box.frame.origin = NSPoint(x: 20, y: 8)
        return box
    }

    /// Asks for the destination of a picture save (nil when cancelled).
    static func choose(suggestedName: String, contentType: UTType) async -> ImageSaveChoice? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-SaveImageFile"), i + 1 < args.count {
            return ImageSaveChoice(url: URL(fileURLWithPath: args[i + 1]), stripPrompt: args.contains("-SaveImageWithoutDetails"))
        }
        #endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        // M4 review P1-4: the checkbox only where the prompt can be stripped (PNG); never a promise we can't keep.
        let box = checkbox()
        if contentType.conforms(to: .png) {
            let container = NSView(frame: NSRect(x: 0, y: 0, width: box.frame.maxX + 20, height: box.frame.height + 16))
            container.addSubview(box)
            panel.accessoryView = container
        }
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        return ImageSaveChoice(url: url, stripPrompt: contentType.conforms(to: .png) && box.state == .on)
    }

    /// Writes the picture at `source` to `choice.url` (replacing a file there); with `stripPrompt`, a copy without the
    /// prompt details. M4 review P1-4: if the prompt cannot be stripped (not a PNG, unreadable metadata) this throws
    /// and writes NOTHING — never the original with the prompt in it.
    static func write(_ source: URL, to choice: ImageSaveChoice) throws {
        guard choice.stripPrompt else {
            try FileCopy.replace(choice.url, withCopyOf: source)
            return
        }
        let data = try Data(contentsOf: source)
        let stripped = try MediaProvenanceWriter.strippingPrompt(data)
        let staging = choice.url.deletingLastPathComponent()
            .appendingPathComponent(".\(choice.url.lastPathComponent).antichat-\(UUID().uuidString)")
        try stripped.write(to: staging)
        let fm = FileManager.default
        if fm.fileExists(atPath: choice.url.path) {
            _ = try fm.replaceItemAt(choice.url, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: choice.url)
        }
    }
}
