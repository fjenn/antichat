// M1.T10 Definition of done: snapshots of the ActionBar (default = shown on hover / last reply, liked, disliked,
// copied, with Read aloud), the VersionSwitcher (first / middle / last; single = hidden), the UserBubble with its
// hover actions and versions, and the UserBubble editing state (InlineEditor with an attachment), Light and Dark.
// Same rig as ComposerSnapshotTests (bitmap scale 2.0, explicit NSAppearance, brand accent, Reduce Motion on).
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ResponseActionsSnapshotTests.
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ResponseActionsSnapshotTests {
    enum Look: String, CaseIterable {
        case light, dark
        var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
    }

    static func render(_ view: some View, width: CGFloat, look: Look) -> NSImage {
        DesignBundle.forceBrandAccent = true
        let root = view
            .frame(width: width, alignment: .leading)
            .padding(Spacing.space4)
            .background(Color.surfaceCanvas)
            .environment(\.reduceMotionOverride, true)
            .environment(\.colorScheme, look == .light ? .light : .dark)
        let host = NSHostingView(rootView: root)
        host.appearance = look.appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = look.appearance
        window.contentView = host
        // Fit until two consecutive settled measurements agree (≤ 2 s). A fixed two passes raced SwiftUI's follow-up
        // pass under `--parallel` load: the InlineEditor's wrapped text was measured 1 pt short (UserBubble.editing:
        // 310 vs 312 px). Tolerance unchanged.
        var last = CGSize.zero
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let size = host.fittingSize
            if size == last { break }
            last = size
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        let size = host.frame.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()),
                                   pixelsHigh: Int((size.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = size
        look.appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static let date = Date(timeIntervalSince1970: 1_793_000_000)

    static func reply(rating: FeedbackRepository.Rating? = nil, version: Int = 1, of total: Int = 1) -> ConversationModel.Message {
        ConversationModel.Message(id: "a", role: .assistant, text: "Done.", status: .done, version: version,
                                  versionCount: total, createdAt: date, rating: rating)
    }

    func check(_ view: some View, width: CGFloat, name: String) {
        for look in Look.allCases {
            assertSnapshot(of: Self.render(view, width: width, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "responseActions")
        }
    }

    @Test func actionBarStates() {
        let states: [(String, ActionBar)] = [
            ("default", ActionBar(message: Self.reply(), engaged: .constant(false))),
            ("liked", ActionBar(message: Self.reply(rating: .liked), engaged: .constant(false))),
            ("disliked", ActionBar(message: Self.reply(rating: .disliked), engaged: .constant(false))),
            ("copied", ActionBar(message: Self.reply(), copied: true, engaged: .constant(false))),
            ("readAloud", ActionBar(message: Self.reply(), voiceInstalled: true, engaged: .constant(false))),
            ("versions", ActionBar(message: Self.reply(version: 2, of: 3), engaged: .constant(false))),
        ]
        for (name, bar) in states { check(bar, width: 360, name: "ActionBar.\(name)") }
    }

    @Test func versionSwitcherStates() {
        for (name, index, total) in [("first", 1, 3), ("middle", 2, 3), ("last", 3, 3), ("single", 1, 1)] {
            check(HStack { VersionSwitcher(index: index, total: total, id: "v", onStep: { _ in }); Spacer() }
                    .frame(height: 26),
                  width: 160, name: "VersionSwitcher.\(name)")
        }
    }

    @Test func userBubbleStates() {
        let user = ConversationModel.Message(
            id: "u", role: .user, text: "Tell me about the harbour town.", status: .done, version: 2, versionCount: 2,
            attachments: [.init(id: "p", displayName: "Pasted text", uti: "public.utf8-plain-text", path: nil, isImage: false)])
        var hover = UserBubble(message: user, isEditing: false, editText: .constant(""), editAttachments: [],
                               onRemoveEditAttachment: { _ in }, onCancelEdit: {}, onSubmitEdit: {},
                               actions: UserMessageActions(), hasVersions: true, copied: false, busy: false)
        hover.showsActions = true
        check(hover, width: 560, name: "UserBubble.hover")
        let editing = UserBubble(message: user, isEditing: true, editText: .constant(user.text),
                                 editAttachments: user.attachments, onRemoveEditAttachment: { _ in }, onCancelEdit: {},
                                 onSubmitEdit: {}, actions: UserMessageActions(), hasVersions: true, copied: false,
                                 busy: false)
        check(editing, width: 560, name: "UserBubble.editing")
    }
}
}  // extension WindowSuites
