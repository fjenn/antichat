// M4.T12 (R-032, S-13): the done card with its actions, the variant strip and the viewer — the in-process legs of
// AT-032 (the XCUITest leg is ImageViewerTests, pending Q-015). Snapshots light/dark (the card and the viewer have no
// Evil- or Incognito-specific styling: both use the window's tokens).
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ImageResultCardTests.
import AntiChatHarness
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ImageResultCardTests {
    @Test func doneCardUsesTheStoredCopyAndOpensTheViewer() throws {
        let png = try ImageJobCardTests.gradient()
        let done = ToolActivity(id: "c1", tool: "create_image", state: .done, argumentsJSON: #"{"prompt":"p","aspect":"3:2"}"#,
                                result: ImageTurnPolicy.Outcome.done(imageID: "a1", width: 96, height: 64, path: png).resultJSON)
        #expect(ImageJobActivity.storedPath(done) == png)
        #expect(ImageJobActivity.artifactID(done) == "a1")
        var opened: ImageViewerTarget?
        let card = ImageResultCard(paths: [png], aspect: 1.5, promptUsed: "p", artifactID: "a1")
            .environment(\.openImageViewer, ImageViewerOpener { opened = $0 })
        _ = ResponseActionsSnapshotTests.render(card, width: 420, look: .light)
        ImageResultCard.open(paths: [png], selected: 0, artifactID: "a1", opener: ImageViewerOpener { opened = $0 })
        #expect(opened == ImageViewerTarget(paths: [png], selected: 0, artifactID: "a1", current: png))
    }

    @Test func versionRailNewestFirstWithOperations() {
        let versions = [ImageVersionItem(n: 1, path: "/a", operation: "generate"), ImageVersionItem(n: 2, path: "/b", operation: "edit"),
                        ImageVersionItem(n: 3, path: "/c", operation: nil)]
        #expect(VersionRail.ordered(versions).map(\.n) == [3, 2, 1])
        #expect(versions[0].operationKey == CopyKey("viewer.op.generate"))
        #expect(versions[1].operationKey == CopyKey("viewer.op.edit"))
        #expect(versions[2].operationKey == nil)
        // Every lineage operation has a label in the copy deck.
        for op in ArtifactOperation.allCases {
            #expect(!CopyKey("viewer.op.\(op.rawValue)").string().hasPrefix("viewer."), "\(op)")
        }
    }

    @Test func conversationModelResolvesTheVersionChain() throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "pics")
        let repo = ArtifactRepository(db)
        let art = try repo.create(chatID: chat.id, kind: "image", title: "image.png")
        for (i, op) in [ArtifactOperation.generate, .edit].enumerated() {
            let blob = try AttachmentRepository(db).insert(sha256: "s\(i)", size: 1, path: "/tmp/v\(i).png", origin: .generated,
                                                            messageID: nil, displayName: "image.png", uti: "public.png")
            try repo.addVersion(artifactID: art.id, blobID: blob.blobID, operation: op)
        }
        let items = ImageViewerTarget.versions(artifactID: art.id, database: db)
        #expect(items.map { ImageVersionItem(n: $0.n, path: $0.path, operation: $0.operation) }
                == [ImageVersionItem(n: 1, path: "/tmp/v0.png", operation: "generate"),
                    ImageVersionItem(n: 2, path: "/tmp/v1.png", operation: "edit")])
        #expect(items.allSatisfy { $0.versionID != nil })
        // M4.T13: an edit of the newest version names the artifact; of an older one, that version (a sibling branch).
        var t = ImageViewerTarget(paths: ["/tmp/v1.png"], selected: 0, artifactID: art.id, current: "/tmp/v1.png", versions: items)
        #expect(t.sourceID == art.id)
        t.current = "/tmp/v0.png"
        #expect(t.sourceID == items[0].versionID)
        #expect(ImageViewerTarget(paths: [], selected: 0, artifactID: nil, current: "/x").sourceID == nil)
        #expect(ImageViewerTarget.versions(artifactID: "missing", database: db).isEmpty)
    }

    @Test func snapshots() throws {
        let png = try ImageJobCardTests.gradient()
        let older = try ImageJobCardTests.gradient()
        let versions = [ImageVersionItem(n: 1, path: older, operation: "generate"), ImageVersionItem(n: 2, path: png, operation: "edit")]
        for look in ResponseActionsSnapshotTests.Look.allCases {
            let card = ImageResultCard(paths: [png], aspect: 1.5, promptUsed: "a lighthouse", artifactID: "a1", forceActions: true)
            assertSnapshot(of: ResponseActionsSnapshotTests.render(card, width: 420, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98), named: "card-\(look.rawValue)", testName: "imageResultCard")
            let strip = ImageResultCard(paths: [png, png, png], aspect: 1.5, artifactID: "a1")
            assertSnapshot(of: ResponseActionsSnapshotTests.render(strip, width: 420, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98), named: "variants-\(look.rawValue)", testName: "imageResultCard")
            // With its editor (Describe the change, Erase, Remove background), as the chat opens it.
            let viewer = ImageViewer(target: ImageViewerTarget(paths: [png], selected: 0, artifactID: "a1", current: png, versions: versions),
                                     onEdit: { _ in }, onLocalEdit: { _ in .failed }, onClose: {})
                .frame(width: 900, height: 560)
            assertSnapshot(of: ResponseActionsSnapshotTests.render(viewer, width: 900, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98), named: "viewer-\(look.rawValue)", testName: "imageViewer")
            // VQ r65 (S-13): the viewer beyond idle — a first picture (no version rail), Erase with a stroke,
            // Remove background running, its "no subject" notice, and the repair card (D-006: no edit without the check).
            let single = ImageViewerTarget(paths: [png], selected: 0, artifactID: "a1", current: png,
                                           versions: [ImageVersionItem(n: 1, path: png, operation: "generate")])
            let states: [(String, ImageViewerTarget, ImageViewer.Start)] = [
                ("firstPicture", single, .init()),
                ("erasing", target(png, versions), .init(erasing: true, strokes: [MaskStroke(points: [CGPoint(x: 0.3, y: 0.45),
                                                                                                    CGPoint(x: 0.6, y: 0.55)], radius: 0.06)])),
                ("busy", target(png, versions), .init(busy: true)),
                ("noSubject", target(png, versions), .init(notice: CopyKey("editor.removeBg.none"))),
                ("safetyMissing", target(png, versions), .init(safetyMissing: 12_400_000)),
            ]
            for (name, t, start) in states {
                let v = ImageViewer(target: t, onEdit: { _ in }, onLocalEdit: { _ in .failed }, onClose: {}, start: start)
                    .frame(width: 900, height: 560)
                assertSnapshot(of: ResponseActionsSnapshotTests.render(v, width: 900, look: look),
                               as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)",
                               testName: "imageViewer")
            }
        }
    }

    private func target(_ png: String, _ versions: [ImageVersionItem]) -> ImageViewerTarget {
        ImageViewerTarget(paths: [png], selected: 0, artifactID: "a1", current: png, versions: versions)
    }
}
}
