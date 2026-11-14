// M4.T10 step 5: the drag-out item provider yields a file URL with the display name and the blob's exact bytes;
// images also yield PNG data (Finder / Mail receive a real file; cross-app drag is vq-05 step 21, computer use).
import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AntiChatUI

@Suite(.enabled(if: FileFixtures.available, "fixtures/docs missing"), .isolatedSettings)
struct DragOutProviderTests {
    static func fileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
            }
        }
    }

    @Test func providerYieldsNamedCopyWithSameBytes() async throws {
        for url in FileFixtures.cardSet {
            let shown = "Shown – \(url.lastPathComponent)"
            let provider = DragOut.itemProvider(for: FileCardItem(url: url, displayName: shown))
            #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
            let dropped = try await Self.fileURL(from: provider)
            #expect(dropped.lastPathComponent == shown)
            #expect(try Data(contentsOf: dropped) == Data(contentsOf: url))
        }
    }

    @Test func imagesAlsoExportPNG() async throws {
        let photo = FileFixtures.cardSet[5]
        let provider = DragOut.itemProvider(for: FileCardItem(url: photo))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let pdfProvider = DragOut.itemProvider(for: FileCardItem(url: FileFixtures.cardSet[0]))
        #expect(!pdfProvider.hasItemConformingToTypeIdentifier(UTType.png.identifier))
    }

    @Test func unsafeNamesAreSanitised() {
        #expect(DragOut.safeName("a/b:c.pdf", fallbackExtension: "pdf") == "a-b-c.pdf")
        #expect(DragOut.safeName("  ", fallbackExtension: "csv") == "file.csv")
        #expect(DragOut.safeName("..hidden.txt", fallbackExtension: "txt") == "hidden.txt")
    }
}
