// Q-015 r4 (M9.T03): AntiChat.app runs as `AntiChatApplication` (the accessibility hit-test workaround), and that
// class changes nothing but `accessibilityHitTest(_:)`. Hosted by the app, so `NSApp` is the instance `Entry.main`
// created. Before r4 the launch hooks reached `NSApplication.shared` first and Info.plist's principal class was ignored.
import AppKit
import ObjectiveC
import XCTest

final class PrincipalClassTests: XCTestCase {
    @MainActor
    func testTheAppRunsAsAntiChatApplication() throws {
        XCTAssertEqual(NSStringFromClass(type(of: NSApplication.shared)), "AntiChatApplication")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSPrincipalClass") as? String, "AntiChatApplication")
    }

    /// No event dispatch, mouse hit testing, menu, window or termination behaviour changes: the class defines exactly
    /// one method of its own.
    func testItOverridesOnlyTheAccessibilityHitTest() throws {
        let cls: AnyClass = try XCTUnwrap(NSClassFromString("AntiChatApplication"))
        XCTAssertTrue(cls.superclass() === NSApplication.self, "a direct NSApplication subclass")
        var count: UInt32 = 0
        let list = try XCTUnwrap(class_copyMethodList(cls, &count))
        defer { free(list) }
        let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }
            .filter { ![".cxx_destruct", "init", "initWithCoder:"].contains($0) }  // compiler-made (inherited initialisers)
        XCTAssertEqual(names, ["accessibilityHitTest:"])
        var ivars: UInt32 = 0
        free(class_copyIvarList(cls, &ivars))
        XCTAssertEqual(ivars, 0, "no state of its own")
    }
}
