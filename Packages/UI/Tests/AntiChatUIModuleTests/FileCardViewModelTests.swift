// M4.T10 task checks: FileCard actions on the fixture set (PDF/DOCX/XLSX/PPTX/CSV + a CC0 photo standing in for an
// image result, BUILD-ORDER dependency fix 1), thumbnails (disk cache, never for incognito) and every card state
// as a snapshot. Fixtures: $ANTICHAT_FIXTURES or the fixtures submodule.
import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AntiChatDesign
@testable import AntiChatUI

enum FileFixtures {
    static var root: URL? {
        var roots: [URL] = []
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env))
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        roots.append(dir.appendingPathComponent("fixtures"))
        return roots.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("docs/pdf/text-10p.pdf").path) }
    }

    static var available: Bool { root != nil }

    /// The six card fixtures (M4.T10 step 5).
    static var cardSet: [URL] {
        guard let root else { return [] }
        return ["docs/pdf/text-10p.pdf", "docs/office/report.docx", "docs/office/budget.xlsx", "docs/office/deck.pptx",
                "docs/office/notes.csv", "images/photos-cc0/001.jpg"].map { root.appendingPathComponent($0) }
    }

    static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filecard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@MainActor
final class RecordingFileActions: FileActionPerforming {
    var opened: [URL] = []
    var revealed: [URL] = []
    var saveRequests: [(String, UTType)] = []
    var destination: URL?

    func open(_ url: URL) -> Bool { opened.append(url); return true }
    func reveal(_ url: URL) { revealed.append(url) }
    func chooseSaveDestination(suggestedName: String, contentType: UTType) async -> URL? {
        saveRequests.append((suggestedName, contentType))
        return destination
    }
}

@MainActor
@Suite(.enabled(if: FileFixtures.available, "fixtures/docs missing (tools/fixtures/make-office.py)"), .isolatedSettings)
struct FileCardViewModelTests {
    @Test func openSaveRevealOnFixtures() async throws {
        let scratch = try FileFixtures.scratch()
        for url in FileFixtures.cardSet {
            let actions = RecordingFileActions()
            let model = FileCardViewModel(item: FileCardItem(url: url, displayName: "Shown \(url.lastPathComponent)"),
                                          actions: actions)
            model.open()
            model.reveal()
            #expect(actions.opened.count == 1 && actions.opened.first != url, "Open hands out a named copy (M6 review #6)")
            #expect(actions.opened.first?.lastPathComponent == "Shown \(url.lastPathComponent)")
            #expect(actions.revealed == [url])

            actions.destination = scratch.appendingPathComponent("saved-\(url.lastPathComponent)")
            let saved = try #require(await model.saveAs())
            #expect(actions.saveRequests.first?.0 == "Shown \(url.lastPathComponent)")
            #expect(try Data(contentsOf: saved) == Data(contentsOf: url))
            #expect(FileManager.default.fileExists(atPath: url.path), "Save As copies; the blob stays")
            // Saving again over the same destination replaces it.
            #expect(await model.saveAs() == saved)
        }
    }

    @Test func kindsAndLabels() throws {
        let kinds = FileFixtures.cardSet.map { FileCardViewModel(item: FileCardItem(url: $0)).kind }
        #expect(kinds == [.pdf, .document, .spreadsheet, .presentation, .csv, .image])
        let model = FileCardViewModel(item: FileCardItem(url: FileFixtures.cardSet[0], size: 13_808, version: 2))
        #expect(model.typeLabel == "PDF")
        #expect(model.versionLabel?.string == "Version 2")
        #expect(model.subtitle.hasPrefix("PDF · ") && model.subtitle.hasSuffix(" · Version 2"))
    }

    @Test func actionsDisabledUntilReady() async {
        let actions = RecordingFileActions()
        actions.destination = URL(fileURLWithPath: "/tmp/never")
        for state in [FileCardItem.State.generating(progress: 0.3), .error(reason: CopyKey("file.createFailed"))] {
            let model = FileCardViewModel(item: FileCardItem(url: FileFixtures.cardSet[0], state: state), actions: actions)
            model.open(); model.reveal(); model.quickLook()
            #expect(await model.saveAs() == nil)
            #expect(model.quickLookURL == nil)
        }
        #expect(actions.opened.isEmpty && actions.revealed.isEmpty && actions.saveRequests.isEmpty)
        let ready = FileCardViewModel(item: FileCardItem(url: FileFixtures.cardSet[0], state: .newVersion), actions: actions)
        ready.quickLook()
        #expect(ready.quickLookURL == FileFixtures.cardSet[0], "click / Space opens Quick Look")
    }

    @Test func thumbnailsCacheOnDiskButNeverForIncognito() async throws {
        let dir = try FileFixtures.scratch()
        let cache = ThumbnailCache(directory: dir)
        let pdf = FileFixtures.cardSet[0]
        let image = await cache.thumbnail(for: pdf, side: 44, incognito: true)
        #expect(image != nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
        let photo = FileFixtures.cardSet[5]
        #expect(await cache.thumbnail(for: photo, side: 44, incognito: false) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        // A fresh cache instance reads the PNG instead of asking Quick Look again.
        let second = ThumbnailCache(directory: dir)
        #expect(await second.thumbnail(for: photo, side: 44, incognito: false) != nil)
        #expect(await second.generated == 0)
    }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .enabled(if: FileFixtures.available, "fixtures/docs missing"), .isolatedSettings)
struct FileCardSnapshotTests {
    @Test func everyState() {
        let pdf = FileFixtures.cardSet[0]
        let states: [(String, FileCardItem)] = [
            ("ready", FileCardItem(url: pdf, displayName: "Quarterly report.pdf", size: 13_808, version: 1)),
            ("generating", FileCardItem(url: pdf, displayName: "Quarterly report.pdf", state: .generating(progress: nil))),
            ("newVersion", FileCardItem(url: pdf, displayName: "Quarterly report.pdf", size: 14_100, version: 2, state: .newVersion)),
            ("error", FileCardItem(url: pdf, displayName: "Quarterly report.pdf", state: .error(reason: CopyKey("file.createFailed")))),
            ("sheet", FileCardItem(url: FileFixtures.cardSet[2], displayName: "budget.xlsx", size: 5_894)),
        ]
        for (name, item) in states {
            let card = FileCard(model: FileCardViewModel(item: item), showsThumbnail: false)
            for look in ResponseActionsSnapshotTests.Look.allCases {
                assertSnapshot(of: ResponseActionsSnapshotTests.render(card, width: FileCard.width, look: look),
                               as: .image(precision: 1, perceptualPrecision: 0.98),
                               named: "\(name)-\(look.rawValue)", testName: "filecard")
            }
        }
    }
}
}  // extension WindowSuites
