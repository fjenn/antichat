// M6 review #4 (incognito outputs leave no disk traces), #6 (Open never hands out the content-addressed blob) and
// #18 (long non-Latin names fit APFS's 255-byte limit).
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AntiChatTools
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct FileOutReviewTests {
    static func file(in dir: URL, _ name: String = "abc123.pdf") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: FileFixtures.root!.appendingPathComponent("docs/pdf/text-10p.pdf"), to: url)
        return url
    }

    @Test(.enabled(if: FileFixtures.available)) func openHandsOutACopyNotTheBlob() throws {
        let dir = try FileFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try Self.file(in: dir)
        let original = try Data(contentsOf: blob)
        let actions = RecordingFileActions()
        let vm = FileCardViewModel(item: FileCardItem(url: blob, displayName: "Report.pdf"), actions: actions)
        vm.open()
        let opened = try #require(actions.opened.first)
        #expect(opened != blob && opened.lastPathComponent == "Report.pdf")
        // An app that saves in place (Preview autosave) changes the copy only.
        try Data("annotated".utf8).write(to: opened)
        #expect(try Data(contentsOf: blob) == original)
        vm.open()
        #expect(actions.opened.count == 2 && actions.opened[1] != opened, "each Open gets a fresh copy")
        #expect(try Data(contentsOf: actions.opened[1]) == original)
    }

    @Test(.enabled(if: FileFixtures.available)) func incognitoCopiesStayInTheSessionDirectory() throws {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-incognito-out-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: session) }
        let blob = try Self.file(in: session)
        let item = FileCardItem(url: blob, displayName: "Secret.pdf")
        #expect(item.incognito)
        #expect(!FileCardItem(url: URL(fileURLWithPath: "/tmp/x.pdf")).incognito)
        let actions = RecordingFileActions()
        let vm = FileCardViewModel(item: item, actions: actions)
        let shared = vm.sharedURL()
        vm.open()
        let drag = try DragOut.namedCopy(of: blob, displayName: "Secret.pdf")
        for u in [shared, actions.opened.first!, drag] {
            #expect(u.standardizedFileURL.path.hasPrefix(session.standardizedFileURL.path), "\(u.path) is outside the session dir")
        }
        try FileManager.default.removeItem(at: session)
        for u in [shared, drag] { #expect(!FileManager.default.fileExists(atPath: u.path), "the copies go with the session") }
    }

    @Test(.enabled(if: FileFixtures.available)) func incognitoThumbnailNeverReachesTheDiskCache() async throws {
        let cacheDir = try FileFixtures.scratch()
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("AntiChat-incognito-out-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDir); try? FileManager.default.removeItem(at: session) }
        let blob = try Self.file(in: session)
        let cache = ThumbnailCache(directory: cacheDir)
        // The output-card call sites pass no incognito flag (incognito: false).
        #expect(await cache.thumbnail(for: blob, side: 44, incognito: false) != nil)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        #expect(written.isEmpty, "incognito thumbnail written to the disk cache: \(written)")
    }

    @Test func longNonLatinNamesFitAPFS() throws {
        let title = String(repeating: "報告書", count: 40)  // 120 characters, 360 bytes
        let name = FileOutNames.filename(title: title, ext: "pdf")
        #expect(name.utf8.count <= 240 && name.hasSuffix(".pdf") && name.hasPrefix("報告書"), "\(name.utf8.count)")
        let safe = DragOut.safeName(String(repeating: "é", count: 300) + ".docx", fallbackExtension: "docx")
        #expect(safe.utf8.count <= 240 && safe.hasSuffix(".docx"))
        let dir = try FileFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = dir.appendingPathComponent("abc.pdf")
        try Data("x".utf8).write(to: blob)
        let copy = try DragOut.namedCopy(of: blob, displayName: title + ".pdf")
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }
}
