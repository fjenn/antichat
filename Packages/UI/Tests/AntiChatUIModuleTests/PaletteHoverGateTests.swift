// UP-CP-004 (vendored CommandPaletteKit): a hover takes the ⌘K selection only when the pointer itself moved. Rows
// appearing under a resting cursor (palette opened over it, filtering, a tab switch) must leave the keyboard's
// selection on the first row, so ↓ moves one row at a time from the top (PaletteWindowTests.noResults… failed
// whenever the test machine's cursor rested over the palette list).
import CoreGraphics
import Foundation
import Testing
@testable import CommandPaletteKit

@Suite(.isolatedSettings) struct PaletteHoverGateTests {
    @Test func restingPointerUnderNewRowsDoesNotSelect() {
        var gate = HoverSelectionGate()
        let resting = CGPoint(x: 670, y: 626)
        gate.pointerBaseline(resting)  // rows shown or changed with the cursor already there
        let h1 = gate.allowsHoverSelection(pointer: resting)
        #expect(!h1)
        let h2 = gate.allowsHoverSelection(pointer: resting)
        #expect(!h2)  // a second row sliding under it
    }

    @Test func movedPointerSelects() {
        var gate = HoverSelectionGate()
        gate.pointerBaseline(CGPoint(x: 670, y: 626))
        let h3 = gate.allowsHoverSelection(pointer: CGPoint(x: 670, y: 600))
        #expect(h3)
        let h4 = gate.allowsHoverSelection(pointer: CGPoint(x: 670, y: 560))
        #expect(h4)  // on into the next row
    }

    @Test func keyboardSuppressionStillApplies() {
        var gate = HoverSelectionGate()
        let now = Date()
        gate.pointerBaseline(CGPoint(x: 0, y: 0))
        gate.keyboardDidMove(at: now)
        let h5 = gate.allowsHoverSelection(pointer: CGPoint(x: 5, y: 5), at: now.addingTimeInterval(0.1))
        #expect(!h5)
        let h6 = gate.allowsHoverSelection(pointer: CGPoint(x: 9, y: 9), at: now.addingTimeInterval(1))
        #expect(h6)
    }

    @Test func noPointerLocationKeepsUpstreamBehaviour() {
        var gate = HoverSelectionGate()
        gate.pointerBaseline(nil)
        let h7 = gate.allowsHoverSelection(pointer: nil)
        #expect(h7)
    }
}
