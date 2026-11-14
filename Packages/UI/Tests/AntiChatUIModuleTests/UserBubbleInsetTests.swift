// Q-015 r3: the user bubble's left inset follows the column the row really has (the side panel narrows it), so a short
// request stays one wide line instead of a 53 pt sliver.
import CoreGraphics
import Testing
@testable import AntiChatUI

@MainActor @Suite(.isolatedSettings) struct UserBubbleInsetTests {
    @Test func insetIsThirtyPercentOfTheNarrowerOfReadingWidthAndRow() {
        #expect(abs(UserBubble.leadingInset(readingWidth: 760, rowWidth: nil) - 760 * 0.3) < 0.001)
        #expect(abs(UserBubble.leadingInset(readingWidth: 760, rowWidth: 311) - 311 * 0.3) < 0.001)
        #expect(abs(UserBubble.leadingInset(readingWidth: 760, rowWidth: 900) - 760 * 0.3) < 0.001)
        let bubble = 311 - UserBubble.leadingInset(readingWidth: 760, rowWidth: 311)
        #expect(bubble > 200, "the bubble keeps 70 % of a narrow column")
    }
}
