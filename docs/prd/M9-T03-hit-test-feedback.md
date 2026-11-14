# M9.T03: transcript accessibility hit test (Q-015 r3 → r4)

Status: **round 4 done; workaround kept, no Feedback filed yet (no minimal repro)**. This page records what was measured. Round 3 called the defect "Apple side". Round
4 showed that this is only partly true.

## Symptom
Every control inside the chat transcript was "Not hittable" to XCUITest. The repro is
`ImageJobCardTests/testStopWithinOneSecond`: the hit test at the card's Stop button returned the `transcript`
AXScrollArea. The same happens to VoiceOver's mouse-follow, Switch Control point scanning and Accessibility Inspector,
because all of them use `AXUIElementCopyElementAtPosition`.

## What round 4 measured
Tools: a standalone SwiftUI program, and `axhit`, a small AX client that finds an element by identifier and hit-tests
its centre through the application element and the system-wide element. `axhit` ran against the live app while the
XCUITest ran.

1. **Standalone repro, real AX path:** `ScrollView { LazyVStack { Button } }` with every transcript modifier.
   `AXUIElementCopyElementAtPosition` returns the **button**. So a SwiftUI ScrollView on macOS 26 is *not* broken by
   itself, and round 3's "Apple defect" verdict was wrong as stated.
   - An in-process `NSWindow.accessibilityHitTest(_:)` does return the AXScrollArea, while the window's hosting view
     returns the button. AppKit does not use that path for remote clients, so it explains nothing.
2. **The live app, same point:** both the application and the system-wide hit test return the `transcript`
   AXScrollArea. The element chain and the frames are correct: Button ⊂ `imageJobWaiting` ⊂ `assistantMessage` ⊂
   `transcriptColumn` ⊂ `transcript`.
3. **The principal class was never used.** The launch hooks in `Entry.main` touch `NSApplication.shared` before
   SwiftUI's `App.main()`. That creates a plain NSApplication, and Info.plist's NSPrincipalClass is then ignored
   (checked with lldb). `Entry.main` now creates `AntiChatApplication` first.
4. **With `AntiChatApplication.accessibilityHitTest(_:)` live:**
   - When the answer is a SwiftUI hosting scroll view, the override asks the hosting views above it (`ScrollViewHitTest`).
   - The hit test then descends into the transcript and lands on **`pendingDot`**, the reply's "Thinking…" dot shown
     under a tool card.
   - The dot's AX frame is the whole reply (532 × 415 pt). It is listed after the card, so it wins every point of a
     pending reply, the Stop button included.
5. **Why the dot had the reply's frame (app bug, fixed).** Moving the dot out of StatusVerbView's `TimelineView` and
   giving it a still 8 pt frame did not change its frame (AX dump: still 532 × 415). A standalone program reproduces it
   deterministically:
   - A container with `.contentShape(Rectangle())` and `.accessibilityElement(children: .contain)` (the reply:
     `AssistantMessageView`, and the same on `UserBubble`).
   - Its first child appears **alone** in it (the pending reply shows only the dot for 2.5 s before the verb and
     before any tool card).
   - That child's AX frame is then the container's content shape, and it stays so after more children arrive. Any
     element does this, a `Text` too, not only the animated dot. The timeline, the phase animator and `onHover` play
     no part: with `.onHover` alone or with no modifier the dot is 8 × 8.
   - Fix: the hover area is a clear background with the content shape (`.background { Color.clear.contentShape(Rectangle()) }`
     before `.onHover`). Hover still covers the whole reply, gaps included, and the dot is 8 × 8 (standalone and the
     live app).
6. **A/B after the dot fix** (`ImageJobCardTests/testStopWithinOneSecond`, `axhit` on the live app at the Stop
   button's centre):

   | `ANTICHAT_AX_HIT_REFINE` | Application hit test | System-wide hit test |
   |---|---|---|
   | `0` (override off) | `transcript` AXScrollArea | `transcript` AXScrollArea |
   | unset (override on) | `imageJobCard.cancel` AXButton | `imageJobCard.cancel` AXButton |

   So the override is still needed in the app. It stays: it changes nothing but `accessibilityHitTest(_:)`
   (`PrincipalClassTests`), it only acts when AppKit's answer is a SwiftUI hosting scroll view, and it only returns an
   element that a hosting view above that scroll view resolved for the same point.
7. **No minimal repro of the remaining defect yet.** The standalone programs return the button for a ScrollView in a
   window, in a `NavigationSplitView` detail, with a toolbar and with a bottom `safeAreaInset`. Something else in the
   app's window (not yet isolated) makes AppKit stop at the transcript's scroll view. No Feedback is filed until a
   standalone repro shows it; then its text goes here and the override's removal condition becomes "the repro returns
   the button".

## Open
- Isolate the remaining scroll-view defect into a standalone repro (bisect the app's window: sidebar, composer
  overlay, side panel, toolbar menus, the window's own NSView overlays), then file Feedback and link it here.
- Other containers with `.contentShape(Rectangle())` and `.contain` children (Settings sidebar, project rows) have
  not been audited for the frame bug; the transcript and user bubble are the ones VoiceOver users hit every turn.
