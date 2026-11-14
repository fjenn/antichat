// AT-207 AC5 (R-207; M2.T14 step 4): while a reply streams or a media job runs, the app holds
// PreventUserIdleSystemSleep named "AntiChat is generating" (downloads: "AntiChat is downloading models", M2.T09); it is
// released when the work ends. Read back from the OS with IOPMCopyAssertionsByProcess — what `pmset -g assertions`
// prints (tools/at/at-207-assertion.sh runs this suite and greps pmset meanwhile).
@testable import AntiChatPlatform
import Darwin
import Foundation
import IOKit.pwr_mgt
import Testing

@Suite(.serialized) struct PowerAssertionTests {
    /// Names of this process's PreventUserIdleSystemSleep assertions.
    static func ourAssertions() -> [String] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return (d[NSNumber(value: getpid())] ?? []).filter { ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertPreventUserIdleSystemSleep }
            .compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    /// The OS-side name of one specific assertion id, nil once it is released. Reading back by id (not by name over all
    /// of this process's assertions) keeps the suite deterministic while other suites hold same-named assertions.
    static func osName(of id: IOPMAssertionID) -> String? {
        guard id != 0, let props = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { return nil }
        return props[kIOPMAssertionNameKey] as? String
    }

    @Test func generationHoldsAndReleasesTheAssertion() async throws {
        let tracker = PackActivityTracker()
        #expect(tracker.assertion.assertionID == 0)
        tracker.begin(.chat)
        #expect(tracker.assertion.isHeld)
        let id = tracker.assertion.assertionID
        #expect(Self.osName(of: id) == "AntiChat is generating")
        #expect(Self.ourAssertions().contains("AntiChat is generating"))  // what pmset lists for this process
        try await Task.sleep(for: .milliseconds(800))  // long enough for at-207-assertion.sh's pmset sampler
        tracker.beginJob()
        tracker.end(.chat)
        #expect(tracker.assertion.isHeld, "a media job still runs")
        tracker.endJob()
        #expect(!tracker.assertion.isHeld)
        #expect(Self.osName(of: id) == nil, "released in the OS")
    }

    @Test func downloadAssertionIsSeparate() {
        let gen = PackActivityTracker()
        let dl = PowerAssertion()
        dl.set("downloads", active: true)
        let id = dl.assertionID
        #expect(Self.osName(of: id) == "AntiChat is downloading models")
        #expect(!gen.assertion.isHeld, "a download does not take the generation assertion")
        dl.set("downloads", active: false)
        #expect(Self.osName(of: id) == nil, "released in the OS")
    }
}
