// AT-287 AC2 (R-287, M4.T09): Save writes the picture with its details; "Save without prompt details" writes it with
// no prompt anywhere but keeps the AI mark. `-SaveImageFile` stands in for NSSavePanel (XCUITest cannot drive it) and
// `-SaveImageWithoutDetails` ticks the panel's checkbox.
// Committed, not run on this Mac (Q-015: XCUITest cannot start). The in-process legs that run today:
// MediaProvenanceWriterTests (testPNGFields, testStripKeepsMark) and tools/media/check-getinfo.sh on a saved file.
import AppKit
import ImageIO
import XCTest

final class SaveImageTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func save(stripPrompt: Bool) throws -> Data {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("saved-\(UUID().uuidString).png")
        let app = MediaUIApp.launch(["-SaveImageFile", out.path] + (stripPrompt ? ["-SaveImageWithoutDetails"] : []))
        MediaUIApp.send(app, "Draw me a lighthouse at dusk")
        let save = MediaUIApp.element(app, "imageJobCard.save")
        XCTAssertTrue(save.waitForExistence(timeout: 60))
        save.click()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: out.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return try Data(contentsOf: out)
    }

    static func xmp(_ data: Data, _ path: String) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let m = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return nil }
        return CGImageMetadataCopyStringValueWithPath(m, nil, path as CFString) as String?
    }

    @MainActor
    func testSaveKeepsDetails() throws {
        let data = try save(stripPrompt: false)
        XCTAssertEqual(Self.xmp(data, "Iptc4xmpExt:DigitalSourceType"),
                       "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")
        XCTAssertNotNil(data.range(of: Data("a lighthouse at dusk".utf8)), "prompt in the saved file")
    }

    @MainActor
    func testSaveWithoutPromptKeepsMark() throws {
        let data = try save(stripPrompt: true)
        XCTAssertEqual(Self.xmp(data, "Iptc4xmpExt:DigitalSourceType"),
                       "http://cv.iptc.org/newscodes/digitalsourcetype/trainedAlgorithmicMedia")
        XCTAssertNil(data.range(of: Data("lighthouse".utf8)), "no prompt anywhere in the file")
        XCTAssertNotNil(Self.xmp(data, "xmp:CreatorTool"))
    }
}
