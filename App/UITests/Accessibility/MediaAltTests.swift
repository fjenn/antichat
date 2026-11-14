// AT-NFR-A5 (M9.T02 step 5): a generated picture is spoken as "Generated image: <description>"; a voice session
// leaves a transcript turn for every spoken turn.
import XCTest

final class MediaAltTests: XCTestCase {
    @MainActor func testGeneratedImageHasDescription() {
        // Q-015 r4: the A11y launch's chat script ("basic") only says hello, so no picture was ever made; the media
        // launch scripts a create_image call, a scripted image engine and a tool-capable chat model.
        let app = MediaUIApp.launch()
        MediaUIApp.send(app, "Make a picture of a lighthouse at dusk.")
        let image = MediaUIApp.element(app, "imageJobCard.result")
        XCTAssertTrue(image.waitForExistence(timeout: 30))
        XCTAssertTrue(image.displayText.hasPrefix("Generated image:"))
        XCTAssertGreaterThan(image.displayText.count, "Generated image: ".count)
    }
}
