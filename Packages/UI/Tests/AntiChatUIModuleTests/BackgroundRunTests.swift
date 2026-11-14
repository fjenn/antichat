// The background-run switch (BackgroundRun) and the frontmost guard of the window suites (WindowSuites.swift).
import AntiChatFoundation
import AppKit
@testable import AntiChatUI
import Darwin
import Testing

@Suite(.isolatedSettings) struct BackgroundRunTests {
    @Test func switchFollowsEnvironmentThenAutomationOptions() {
        let probe = LaunchOptions.parse(["-UIProbe", "/tmp/p"])
        let plain = LaunchOptions.parse([])
        #expect(BackgroundRun.wanted(environment: [:], options: probe))
        #expect(BackgroundRun.wanted(environment: ["ANTICHAT_BACKGROUND": "1"], options: plain))
        #expect(!BackgroundRun.wanted(environment: ["ANTICHAT_BACKGROUND": "0"], options: probe))  // XCUITest opt-out
        #expect(!BackgroundRun.wanted(environment: [:], options: plain))  // the owner's own launch
        #expect(BackgroundRun.wanted(environment: ["XCTestConfigurationFilePath": "/x"], options: plain))  // hosted
        // Visual QA capture shows its windows (it posts no input).
        #expect(!BackgroundRun.wanted(environment: [:], options: LaunchOptions.parse(["-VisualQAProbe", "/tmp/vq",
                                                                                       "-ANTICHAT_DEV_CONTAINER", "/tmp/c"])))
    }

    /// AT-NFR-S3: `.prohibited` by default; the soak's `ANTICHAT_BACKGROUND_POLICY=accessory` gives the main thread a
    /// GUI app's priority (46/47 instead of 31) and keeps everything else of a background run.
    @Test func policyIsProhibitedUnlessAccessoryIsAsked() {
        #expect(BackgroundRun.policy(environment: [:]) == .prohibited)
        #expect(BackgroundRun.policy(environment: ["ANTICHAT_BACKGROUND_POLICY": "accessory"]) == .accessory)
        #expect(BackgroundRun.policy(environment: ["ANTICHAT_BACKGROUND_POLICY": "Accessory"]) == .accessory)
        #expect(BackgroundRun.policy(environment: ["ANTICHAT_BACKGROUND_POLICY": "regular"]) == .prohibited)
    }

    @Test func guardFlagsTheTestRunnerInFrontOnly() {
        let me: Set<pid_t> = [getpid(), getppid()]
        #expect(FrontmostGuard.violation(frontmost: 1, frontmostName: "Finder", selfActive: false, forbidden: me, when: "t") == nil)
        #expect(FrontmostGuard.violation(frontmost: nil, frontmostName: nil, selfActive: false, forbidden: me, when: "t") == nil)
        #expect(FrontmostGuard.violation(frontmost: getpid(), frontmostName: "xctest", selfActive: false, forbidden: me, when: "t") != nil)
        #expect(FrontmostGuard.violation(frontmost: getppid(), frontmostName: "swift", selfActive: false, forbidden: me, when: "t") != nil)
        #expect(FrontmostGuard.violation(frontmost: 1, frontmostName: "Finder", selfActive: true, forbidden: me, when: "t") != nil)
    }
}

// RC e8fe19986: under `.prohibited` SwiftUI may leave a scene's window created but never ordered in; the background run
// orders each window the app expects on screen in, concealed, once (a window closed or hidden later stays so).
extension WindowSuites {
    @MainActor @Suite(.isolatedSettings) struct BackgroundRunUnshownWindowTests {
        @Test func ordersAnExpectedUnshownWindowInOnceConcealed() {
            let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                backing: .buffered, defer: false)
            main.isReleasedWhenClosed = false
            main.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { main.orderOut(nil); other.orderOut(nil) }
            let wants: (NSWindow) -> Bool = { $0.identifier?.rawValue.hasPrefix("main-") == true }
            #expect(!main.isVisible)
            BackgroundRun.presentUnshown([main, other], wants: wants)
            #expect(main.isVisible, "the expected window is ordered in")
            #expect(main.alphaValue == 0 && main.ignoresMouseEvents, "concealed")
            #expect(!other.isVisible, "a window the app did not ask for stays out")
            main.orderOut(nil)  // hidden or closed on purpose later
            BackgroundRun.presentUnshown([main, other], wants: wants)
            #expect(!main.isVisible, "once per window")
        }
    }
}
