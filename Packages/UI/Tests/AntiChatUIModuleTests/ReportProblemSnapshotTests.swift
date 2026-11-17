// Report a problem with attachments (owner 2026-11-16): the sheet with two attached items (a screenshot with its
// thumbnail, a document with the glyph) in Light and Dark, and the plain message for each limit. The limits
// themselves are unit-tested in AntiChatPlatformTests (ReportComposerTests.attachmentLimits).
// Re-record after an intended visual change:
//   SNAPSHOT_TESTING_RECORD=all swift test --filter ReportProblemSnapshotTests   (in Packages/UI)
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
import AntiChatPlatform
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ReportProblemSnapshotTests {
    /// A flat-colour PNG and a small text file in a fresh temp folder.
    static func fixtures() throws -> [ReportAttachment] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("report-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0 ..< 64 { for y in 0 ..< 64 { rep.setColor(NSColor(deviceRed: 0.16, green: 0.45, blue: 0.85, alpha: 1), atX: x, y: y) } }
        let shot = dir.appendingPathComponent("Screenshot of the stuck download.png")
        try rep.representation(using: .png, properties: [:])!.write(to: shot)
        let notes = dir.appendingPathComponent("what-i-typed.txt")
        try Data(repeating: 0x61, count: 2_000).write(to: notes)
        return [shot, notes].compactMap(ReportAttachments.measure)
    }

    @Test func sheetWithTwoAttachments() throws {
        let items = try Self.fixtures()
        defer { try? FileManager.default.removeItem(at: items[0].url.deletingLastPathComponent()) }
        #expect(items.count == 2)
        #expect(ReportAttachmentChip.thumbnail(items[0].url) != nil && ReportAttachmentChip.thumbnail(items[1].url) == nil)
        let sheet = ReportProblemSheet(attachments: items,
                                       systemBlock: "AntiChat 0.0.7 (700)\nmacOS 26.1\nApple M3 · 16 GB memory") {}
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(sheet, width: 480, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "twoAttachments-\(look.rawValue)", testName: "reportProblem")
        }
    }

    @Test func aPlainMessagePerLimit() {
        #expect(ReportProblemSheet.message(for: nil) == nil)
        #expect(ReportProblemSheet.message(for: .tooMany)?.string == "You can attach up to 5 items.")
        #expect(ReportProblemSheet.message(for: .tooLarge(name: "clip.mov"))?.string
                == "clip.mov doesn't fit. Attachments can be 15 MB in total.")
        #expect(ReportProblemSheet.message(for: .unreadable(name: "Photos"))?.string
                == "Photos can't be attached. Choose a file, not a folder.")
        let hint = CopyText(CopyKey("report.attach.hint"), ReportProblemSheet.limitArgs).string
        #expect(hint.contains("Up to 5 files") && hint.contains("15 MB") && !hint.contains("{"))
    }
}
}  // extension WindowSuites
