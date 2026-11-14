// M4.T11 task check `SidePanelTests`: open / close / resize (clamped, remembered per window) / version switch (panel
// and in-turn card follow), body per file kind, Edit selection prefill, and the panel on screen for a PDF and a CSV.
import AntiChatFoundation
import AntiChatStorage
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct SidePanelModelTests {
    func defaults() -> UserDefaults {
        UserDefaults.inMemory()
    }

    @Test func openCloseAndVersionSwitch() {
        let model = SidePanelModel(defaults: defaults())
        var followed: [Int] = []
        model.onVersionChange = { followed.append($0.n) }
        let v = (1...3).map { PanelVersion(n: $0, url: URL(fileURLWithPath: "/tmp/report.v\($0).pdf")) }
        model.open(title: "report.pdf", versions: v.reversed())
        #expect(model.isOpen && model.current?.n == 3, "opens on the latest version")
        #expect(model.versionLabel?.string == "Version 3 of 3")
        model.select(version: 1)
        #expect(model.current?.n == 1 && followed == [1])
        model.select(version: 1)
        #expect(followed == [1], "re-selecting the same version is a no-op")
        model.close()
        #expect(!model.isOpen)
        model.open(file: URL(fileURLWithPath: "/tmp/one.csv"))
        #expect(model.versionLabel == nil, "single version: no picker")
    }

    @Test func widthClampsAndIsRememberedPerWindow() {
        let d = defaults()
        let a = SidePanelModel(windowID: "a", defaults: d)
        #expect(a.width == SidePanelModel.defaultWidth)
        a.resize(to: 10)
        #expect(a.width == SidePanelModel.minWidth)
        a.resize(to: 640)
        #expect(SidePanelModel(windowID: "a", defaults: d).width == 640)
        #expect(SidePanelModel(windowID: "b", defaults: d).width == SidePanelModel.defaultWidth)
        a.resize(to: 5000)
        #expect(a.width == SidePanelModel.maxWidth)
    }

    /// Q-015 r2: the remembered width never leaves the conversation less than `minChatWidth` (half on narrow windows).
    @Test func shownWidthLeavesRoomForTheConversation() {
        let model = SidePanelModel(defaults: defaults())
        model.resize(to: 766)
        #expect(model.shownWidth(in: 1600) == 766)
        #expect(model.shownWidth(in: 1200) == 1200 - SidePanelModel.minChatWidth)
        #expect(model.shownWidth(in: 500) == 250)
        #expect(model.shownWidth(in: .infinity) == 766)
        model.resize(to: 400)
        #expect(model.shownWidth(in: 920) == 400)
    }

    @Test func bodyPerKind() {
        let cases: [(String, PanelBody)] = [("a.pdf", .pdf), ("a.csv", .text), ("a.md", .text), ("a.swift", .text),
                                            ("a.png", .image), ("a.jpg", .image), ("a.svg", .web), ("a.html", .web),
                                            ("a.docx", .quickLook), ("a.xlsx", .quickLook), ("a.pptx", .quickLook)]
        let model = SidePanelModel(defaults: defaults())
        for (name, body) in cases {
            model.open(file: URL(fileURLWithPath: "/tmp/\(name)"))
            #expect(model.body == body, "\(name)")
        }
    }

    @Test func editSelectionPrefillsAQuote() {
        let model = SidePanelModel(defaults: defaults())
        var prefill: String?
        model.onEditSelection = { prefill = $0 }
        model.open(file: URL(fileURLWithPath: "/tmp/a.pdf"))
        model.editSelection()
        #expect(prefill == nil, "nothing selected")
        model.selection = "Line one\nLine two"
        #expect(model.canEditSelection)
        model.editSelection()
        #expect(prefill == "> Line one\n> Line two\n\n")
        model.open(file: URL(fileURLWithPath: "/tmp/a.docx"))
        #expect(!model.canEditSelection, "Quick Look bodies have no selection")
    }

    @Test func versionsComeFromArtifactRows() throws {
        let database = try AppDatabase.inMemory()
        let chat = try ChatRepository(database).create(title: "c")
        let attachments = AttachmentRepository(database)
        let repo = ArtifactRepository(database)
        let artifact = try repo.create(chatID: chat.id, kind: "pdf", title: "r.pdf")
        for i in 1...2 {
            let blob = try attachments.insert(sha256: "s\(i)", size: 1, path: "Media/2026/s\(i).pdf", origin: .generated,
                                              messageID: nil, displayName: "r.pdf", uti: "com.adobe.pdf")
            try repo.addVersion(artifactID: artifact.id, blobID: blob.blobID)
        }
        let versions = try SidePanelModel.versions(of: artifact.id, in: repo) { id in
            (try? attachments.blob(id: id)).flatMap { $0 }.map { URL(fileURLWithPath: "/media/\($0.path)") }
        }
        #expect(versions.map(\.n) == [1, 2])
        #expect(versions[1].url.lastPathComponent == "s2.pdf")
    }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .enabled(if: FileFixtures.available, "fixtures/docs missing"), .isolatedSettings)
struct SidePanelTests {
    func host(_ model: SidePanelModel) -> NSWindow {
        let view = SidePanelContainer(model: model) { Color.clear }
            .environment(\.reduceMotionOverride, true)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        return window
    }

    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    @Test func pdfBodyAndSelection() throws {
        let model = SidePanelModel(windowID: "t-\(UUID().uuidString)", defaults: UserDefaults.inMemory())
        let window = host(model)
        model.open(file: FileFixtures.cardSet[0])
        settle()
        let pdf = try #require(find(PDFKitViewType.self, in: window.contentView!))
        #expect(pdf.document?.pageCount == 10)
        // Select page 1's text → Edit selection becomes available.
        pdf.setCurrentSelection(pdf.document?.page(at: 0)?.selection(for: CGRect(x: 0, y: 0, width: 600, height: 800)), animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: pdf)
        settle()
        #expect(model.canEditSelection && model.selection.contains("Chapter 1"))
        model.close()
        // The 320 ms close transition keeps the view until it ends.
        for _ in 0..<10 where find(PDFKitViewType.self, in: window.contentView!) != nil { settle() }
        #expect(find(PDFKitViewType.self, in: window.contentView!) == nil)
    }

    @Test func textBodyForCSV() throws {
        let model = SidePanelModel(windowID: "t-\(UUID().uuidString)", defaults: UserDefaults.inMemory())
        let window = host(model)
        model.open(file: FileFixtures.cardSet[4])
        settle()
        let text = try #require(find(NSTextView.self, in: window.contentView!))
        #expect(text.string.hasPrefix("date,place,item,amount"))
        #expect(!text.isEditable)
    }
}
}  // extension WindowSuites

import PDFKit
typealias PDFKitViewType = PDFView
