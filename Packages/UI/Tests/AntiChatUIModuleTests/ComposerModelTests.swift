// ComposerModelTests (M1.T08, AT-002 unit leg): the composer rules behind R-002's seven criteria that do not
// need a running app — send/stop state machine (3), key mapping (4), Markdown styling + payload (5), paste
// threshold (6), status chips (7), growth and bottom-row rule (2), and the Defaults keys.
import AppKit
import Defaults
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct ComposerModelTests {
    // MARK: (3) Send / Stop

    @Test func emptyComposerShowsDisabledVoiceAndCannotSend() {
        let m = ComposerModel()
        #expect(m.trailingButton == .voice)
        #expect(!m.canSend)
        #expect(!m.send())
        m.text = "  \n "
        #expect(m.trailingButton == .voice, "whitespace only is empty")
    }

    @Test func textEnablesSendAndSendFlipsToStopBeforeTheCallback() {
        let m = ComposerModel()
        m.text = "Hello **there**"
        #expect(m.trailingButton == .send(enabled: true))
        var seenPhase: ComposerModel.Phase?
        var got: ComposerSubmission?
        m.onSend = { s in seenPhase = m.phase; got = s }
        #expect(m.send())
        #expect(seenPhase == .generating, "Stop is visible in the same frame as the send (NFR-U2)")
        #expect(m.trailingButton == .stop)
        #expect(got == ComposerSubmission(markdown: "Hello **there**"))
        #expect(m.text.isEmpty)
        // Return while generating does not send again (T19 adds the follow-up queue).
        m.text = "next"
        #expect(!m.send())
        m.stop()
        #expect(m.trailingButton == .stopping)
        m.turnFinished()
        #expect(m.trailingButton == .send(enabled: true))
        m.text = ""
        #expect(m.trailingButton == .voice)
    }

    @Test func accessibilityIdsSharedWithT06() {
        #expect(SendStopButton.identifier(for: .voice) == "voiceOrSend")
        #expect(SendStopButton.identifier(for: .send(enabled: true)) == "voiceOrSend")
        #expect(SendStopButton.identifier(for: .stop) == "stop")
        #expect(SendStopButton.identifier(for: .stopping) == "stop")
    }

    /// M9.T08: empty is a pale, disabled Send (components.md SendStopButton), not a second voice button.
    @Test func emptyStateIsADisabledSend() {
        let empty = SendStopButton(state: .voice, mode: .normal, queuedPercent: nil, onSend: {}, onStop: {})
        #expect(empty.label.string == CopyText(CopyKey("tip.send")).string)
        #expect(empty.accessibilityLabel.string == CopyText(CopyKey("a11y.send")).string)
    }

    /// M9.T08: the toolbar names the Library, Projects and Chats pages instead of "New chat".
    @Test func toolbarNamesPageRoutes() {
        #expect(MainWindow.pageTitle(.library) == CopyKey("library.title"))
        #expect(MainWindow.pageTitle(.projects) == CopyKey("side.projects"))
        #expect(MainWindow.pageTitle(.chats) == CopyKey("chats.page.title"))
        #expect(MainWindow.pageTitle(.newChat) == nil)
        #expect(MainWindow.pageTitle(.chat("x")) == nil)
    }

    @Test func stopCallsTheHostOnlyWhileGenerating() {
        let m = ComposerModel()
        var stops = 0
        m.onStop = { stops += 1 }
        m.stop()
        #expect(stops == 0)
        m.text = "x"
        m.send()
        m.stop()
        m.stop()
        #expect(stops == 1)
    }

    @Test func queuedAndNoModelStates() {
        let m = ComposerModel()
        m.availability = .queued(percent: 42)
        m.text = "hi"
        #expect(m.trailingButton == .queuedSend)
        #expect(m.canSend)
        m.availability = .noModel
        #expect(!m.canSend)
        #expect(!m.isFieldEnabled)
        #expect(m.placeholder.key == CopyKey("composer.noModel"))
        #expect(!m.handlePaste(String(repeating: "a", count: 20_000)), "no paste cards into a disabled field")
    }

    @Test func placeholderFollowsMode() {
        let m = ComposerModel()
        #expect(m.placeholder.key == CopyKey("composer.placeholder"))
        m.mode = .evil
        #expect(m.placeholder.key == CopyKey("composer.placeholder.evil"))
    }

    // MARK: (4) Keys

    @Test func returnSendsAndShiftReturnInsertsNewlineByDefault() {
        let r = ComposerKeyAction.resolve
        #expect(r(false, false, false, false, false) == .send)
        #expect(r(false, true, false, false, false) == .insertNewline)
        #expect(r(false, false, true, false, false) == .insertNewline)
        #expect(r(true, false, false, false, false) == .send)
    }

    @Test func commandEnterModeSwapsReturnAndCommandReturn() {
        let r = ComposerKeyAction.resolve
        #expect(r(false, false, false, true, false) == .insertNewline)
        #expect(r(true, false, false, true, false) == .send)
        #expect(r(false, true, false, true, false) == .insertNewline)
    }

    @Test func returnDuringIMECompositionIsLeftToTheTextView() {
        #expect(ComposerKeyAction.resolve(command: false, shift: false, option: false, sendWithCommandEnter: false,
                                          hasMarkedText: true) == nil)
    }

    @Test func defaultsKeysAndLaunchArgumentOverride() {
        let ud = UserDefaults.antichat  // the Settings store (the test's own scope), never the real domain
        #expect(Defaults.Keys.sendWithCommandEnter.defaultValue == false)
        #expect(Defaults.Keys.plainTextComposer.defaultValue == false)
        #expect(Defaults.Keys.sendWithCommandEnter.name == "sendWithCommandEnter")
        #expect(Defaults.Keys.plainTextComposer.name == "plainTextComposer")
        defer { Defaults.reset(.sendWithCommandEnter, .plainTextComposer) }
        Defaults[.sendWithCommandEnter] = true
        let m = ComposerModel()
        #expect(m.sendWithCommandEnter)
        #expect(m.keyAction(command: false, shift: false, option: false, hasMarkedText: false) == .insertNewline)
        #expect(m.keyAction(command: true, shift: false, option: false, hasMarkedText: false) == .send)
        // The `-plainTextComposer YES` launch argument writes the same UserDefaults key (NSArgumentDomain).
        ud.set(true, forKey: "plainTextComposer")
        #expect(m.plainTextComposer)
    }

    // MARK: (5) Rich text, Markdown payload

    @Test func boldRunRendersBoldInRichModeAndUnstyledInPlainMode() throws {
        let source = "Make **this bold**, *this italic* and `code`.\n- item"
        let rich = NSTextStorage(string: source)
        #expect(ComposerMarkdownStyler.apply(to: rich, plain: false, scale: 1) == 1)
        let boldAt = (source as NSString).range(of: "this bold").location
        let boldFont = try #require(rich.attribute(.font, at: boldAt, effectiveRange: nil) as? NSFont)
        #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold) || weight(of: boldFont) >= NSFont.Weight.semibold.rawValue)
        let italicAt = (source as NSString).range(of: "this italic").location
        let italicFont = try #require(rich.attribute(.font, at: italicAt, effectiveRange: nil) as? NSFont)
        #expect(italicFont.fontDescriptor.symbolicTraits.contains(.italic))
        let codeAt = (source as NSString).range(of: "code").location
        let codeFont = try #require(rich.attribute(.font, at: codeAt, effectiveRange: nil) as? NSFont)
        #expect(codeFont.isFixedPitch)
        #expect(rich.string == source, "styling never changes the characters: the payload is Markdown")

        let plain = NSTextStorage(string: source)
        #expect(ComposerMarkdownStyler.apply(to: plain, plain: true, scale: 1) == 0)
        var fonts = Set<String>()
        plain.enumerateAttribute(.font, in: NSRange(location: 0, length: plain.length)) { v, _, _ in
            fonts.insert((v as? NSFont)?.fontName ?? "nil")
        }
        #expect(fonts.count == 1, "plain mode: one font over the whole text")
    }

    @Test func stylerKeepsEveryLineOnTheFixedLineBox() {
        let s = NSTextStorage(string: "# Heading\n**b** `c` *i*")
        ComposerMarkdownStyler.apply(to: s, plain: false, scale: 1)
        s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            let p = v as? NSParagraphStyle
            #expect(p?.minimumLineHeight == 24)
            #expect(p?.maximumLineHeight == 24)
        }
    }

    @Test func markersInsideCodeAreNotStyled() {
        let s = NSTextStorage(string: "`**not bold**`")
        #expect(ComposerMarkdownStyler.apply(to: s, plain: false, scale: 1) == 0)
    }

    // MARK: (6) Paste

    @Test func pasteOfExactly10000StaysInlineAnd10001BecomesACard() {
        let m = ComposerModel()
        #expect(!m.handlePaste(String(repeating: "x", count: 10_000)))
        #expect(m.attachments.isEmpty)
        let long = String(repeating: "y", count: 10_001)
        #expect(m.handlePaste(long))
        #expect(m.attachments.count == 1)
        #expect(m.attachments[0].characterCount == 10_001)
        #expect(m.attachments[0].text == long)
        #expect(m.hasContent, "a card alone is sendable")
        #expect(m.usesBottomRow, "attachments move the controls to the bottom row")
        #expect(PasteAttachmentCard.countLabel(m.attachments[0]).string == "Pasted text · 10,001 characters")
        var got: ComposerSubmission?
        m.onSend = { got = $0 }
        m.send()
        #expect(got?.attachments.count == 1)
        #expect(m.attachments.isEmpty)
    }

    @Test func removingTheCardEmptiesTheTray() {
        let m = ComposerModel()
        m.handlePaste(String(repeating: "z", count: 12_000))
        m.removeAttachment(id: m.attachments[0].id)
        #expect(m.attachments.isEmpty)
        #expect(!m.usesBottomRow)
        #expect(m.trailingButton == .voice)
    }

    @Test func pasteThresholdCountsCharactersNotBytes() {
        #expect(!ComposerRules.pasteBecomesCard(String(repeating: "é", count: 10_000)))
        #expect(ComposerRules.pasteBecomesCard(String(repeating: "🙂", count: 10_001)))
    }

    // MARK: (2) Growth and bottom row

    @Test func heightGrowsOneLineAtATimeUpToTwelveThenStays() {
        let heights = (1...15).map { ComposerRules.visibleTextHeight(lines: $0) }
        for n in 1..<12 { #expect(heights[n] - heights[n - 1] == 24) }
        #expect(heights[11] == CGFloat(12 * 24))
        #expect(heights[12] == heights[11] && heights[14] == heights[11])
        #expect(ComposerRules.visibleTextHeight(lines: 0) == 24)
    }

    @Test func windowCapStopsGrowthEarlierButNeverBelowOneLine() {
        #expect(ComposerRules.visibleTextHeight(lines: 12, cap: 100) == 96)
        #expect(ComposerRules.visibleTextHeight(lines: 3, cap: 5) == 24)
    }

    @Test func bottomRowRule() {
        #expect(!ComposerRules.usesBottomRow(textWraps: false, attachmentCount: 0))
        #expect(ComposerRules.usesBottomRow(textWraps: true, attachmentCount: 0))
        #expect(ComposerRules.usesBottomRow(textWraps: false, attachmentCount: 1))
    }

    @Test func wrapIsMeasuredAtTheSingleRowWidth() {
        let font = TypeToken.body.nsFont()
        let short = NSAttributedString(string: "short", attributes: [.font: font])
        let long = NSAttributedString(string: String(repeating: "word ", count: 40), attributes: [.font: font])
        typealias C = ComposerTextView.Coordinator
        #expect(!C.wraps("short", attributed: short, width: 300, currentLines: 1, currentWidth: 600))
        #expect(C.wraps(long.string, attributed: long, width: 300, currentLines: 1, currentWidth: 900),
                "fits the wide bottom-row field but not the single row: stays in the bottom row (no oscillation)")
        #expect(C.wraps("a\nb", attributed: short, width: 300, currentLines: 2, currentWidth: 300))
        #expect(!C.wraps("", attributed: short, width: 300, currentLines: 1, currentWidth: 300))
    }

    // MARK: (7) Status row

    @Test func statusRowIsEmptyUnlessAChipIsSet() {
        #expect(ComposerStatusRow(projectName: nil, mode: nil).isEmpty)
        #expect(!ComposerStatusRow(projectName: "P", mode: nil).isEmpty)
        #expect(!ComposerStatusRow(projectName: nil, mode: .evil).isEmpty)
    }

    /// M9.T08 R6: the memory switch shows while it can change, and once locked only when it is off.
    @Test func memorySwitchShowsWhileChangeableOrOff() {
        let m = ComposerModel()
        #expect(!m.memoryToggleVisible)  // harness host: no switch
        m.showsMemoryToggle = true
        #expect(m.memoryToggleVisible)  // new, empty chat
        m.memoryOffLocked = true
        #expect(!m.memoryToggleVisible)  // after the first message, memory on: nothing to say
        m.memoryOff = true
        #expect(m.memoryToggleVisible)  // memory off for this chat: the locked brain.slash stays
        m.isIncognito = true
        #expect(!m.memoryToggleVisible)  // Q-015 r6: an incognito chat keeps no memory, no switch
    }

    private func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }
}
