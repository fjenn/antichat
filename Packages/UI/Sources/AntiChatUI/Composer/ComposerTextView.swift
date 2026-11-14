// The composer's text field (M1.T08 steps 2, 4, 5, 6): an NSTextView (TextKit 1, so line fragments are countable)
// in an NSScrollView. Rich mode styles the Markdown source inline (bold, italics, code, list markers, headings)
// with attributes only: the characters stay Markdown, so the sent payload is Markdown in both modes.
// Every line uses the `type.body` line box, so growth is in exact 24 pt steps (failure mode "growth jitter").
import AntiChatDesign
import AntiChatFoundation
import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Bindable var model: ComposerModel
    /// The field's widths; the single-row text width (what the one-line layout would give the text) decides
    /// `model.textWraps`. Pushed to the coordinator, never through view state (fix/selection-hang-2).
    let widths: ComposerWidths
    @Environment(\.chatTextScale) private var scale
    @Environment(\.chatFont) private var chatFont  // M1.T23

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false  // attributes are ours; pastes insert plain text (paste(_:) below)
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("composerText")
        textView.setAccessibilityLabel(model.placeholder.string)
        // Files dropped on the field go to the composer (attachments, M5), never inserted as paths.
        textView.unregisterDraggedTypes()
        textView.registerForDraggedTypes([.string])

        let scroll = ComposerScrollView()
        scroll.coordinator = context.coordinator
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        scroll.setAccessibilityIdentifier("composerScroll")

        let c = context.coordinator
        c.textView = textView
        ComposerFocusOwner.adopt(textView, for: model)  // the newest field of this composer owns its focus
        c.scale = scale
        c.chatFont = chatFont
        c.singleRowWidth = widths.singleRow
        widths.onSingleRowChange = { [weak c] w in
            c?.singleRowWidth = w
            c?.scheduleMeasure()
        }
        c.applyBaseAttributes()
        textView.string = model.text
        c.restyle()
        c.bindMenus()  // M1.T17
        return scroll
    }

    /// A new field that replaces the focused one (the empty-state composer docking after the first send, a chat
    /// switch) keeps the focus: the old field leaves the window and AppKit hands first responder to the window, so
    /// the next keystroke went nowhere (Q-015 XCUITest catch-up, AT-001 legs 5–6). Never takes focus from any other
    /// control (a rename field, search, a sheet).
    static func takeOverFocus(_ textView: ComposerNSTextView) {
        // After this layout pass (a run-loop perform, so a nested run loop such as a test settle() runs it too).
        RunLoop.main.perform { [weak textView] in
            MainActor.assumeIsolated {
                guard let tv = textView, let w = tv.window, tv.isEditable, ComposerFocusOwner.owns(tv) else { return }
                let current = w.firstResponder
                if current == nil || current === w || (current is ComposerNSTextView && current !== tv) {
                    w.makeFirstResponder(tv)
                }
            }
        }
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.model = model
        guard let tv = c.textView else { return }
        var needsRestyle = false
        if c.scale != scale || c.chatFont != chatFont {
            c.scale = scale
            c.chatFont = chatFont
            c.applyBaseAttributes()
            needsRestyle = true
        }
        if c.plain != model.plainTextComposer { needsRestyle = true }
        if tv.string != model.text, !tv.hasMarkedText() {
            c.suppressMenuUpdates = true  // no observable writes inside a SwiftUI update (M1.T17)
            tv.string = model.text
            c.suppressMenuUpdates = false
            needsRestyle = true
            DispatchQueue.main.async { [weak c] in c?.updateMenus() }
        }
        // NFR-U2: set only what changed (a send updates this view; an accessibility label set posts a change).
        let enabled = model.isFieldEnabled
        if tv.isEditable != enabled { tv.isEditable = enabled }
        if tv.isSelectable != enabled { tv.isSelectable = enabled }
        let label = model.placeholder.string
        if tv.accessibilityLabel() != label { tv.setAccessibilityLabel(label) }
        if needsRestyle { c.restyle() }
        c.singleRowWidth = widths.singleRow
        widths.onSingleRowChange = { [weak c] w in
            c?.singleRowWidth = w
            c?.scheduleMeasure()
        }
        c.scheduleMeasure()  // writes the model only when a value changed, so this cannot loop
        if c.lastFocusRequest != model.focusRequest {
            c.lastFocusRequest = model.focusRequest
            DispatchQueue.main.async { [weak tv] in
                // Q-015 r6: only the composer's current field answers. While the empty-state composer docks, the
                // outgoing field stays in the window for the dock animation and saw the same request (the send's
                // `focusRequest`); taking focus back, it then left the window holding it, and the docked field had
                // none: the next keystroke went nowhere (WindowLayout disclaimer, J08's second send).
                guard let tv, let w = tv.window, tv.isEditable, ComposerFocusOwner.owns(tv) else { return }
                // NFR-U2: a send asks for focus the field almost always has; re-making it first responder ran the
                // focus change (and its accessibility focus update) for nothing.
                if w.firstResponder !== tv { w.makeFirstResponder(tv) }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var model: ComposerModel
        weak var textView: ComposerNSTextView?
        var scale: CGFloat = 1
        var chatFont: ChatFont = .default  // M1.T23
        var plain = false
        var singleRowWidth: CGFloat = 0
        var lastFocusRequest = 0
        var suppressMenuUpdates = false
        private var measureScheduled = false

        init(model: ComposerModel) {
            self.model = model
            self.lastFocusRequest = model.focusRequest
        }

        var lineHeight: CGFloat { ComposerRules.lineHeight(scale: scale) }

        func applyBaseAttributes() {
            textView?.typingAttributes = ComposerMarkdownStyler.baseAttributes(scale: scale, font: chatFont)
            textView?.insertionPointColor = .textPrimary
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if model.text != tv.string { model.text = tv.string }
            if !tv.hasMarkedText() { restyle() }
            measure()
            updateMenus()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if !suppressMenuUpdates { updateMenus() }
        }

        // MARK: Menus (M1.T17)

        /// Picks edit the text through the text view, so they are one undo step and restyle like typing.
        func bindMenus() {
            model.menus.replaceText = { [weak self] range, replacement in
                guard let tv = self?.textView, NSMaxRange(range) <= (tv.string as NSString).length else { return }
                if tv.shouldChangeText(in: range, replacementString: replacement) {
                    tv.textStorage?.replaceCharacters(in: range, with: replacement)
                    tv.didChangeText()
                }
                tv.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
                self?.updateMenus()
            }
        }

        /// Reports text + caret to the menus and the trigger's x offset (the inline menu's anchor).
        func updateMenus() {
            guard let tv = textView else { return }
            let menus = model.menus
            menus.update(text: tv.string, caret: tv.selectedRange().location, hasMarkedText: tv.hasMarkedText())
            guard let t = menus.trigger, let lm = tv.layoutManager, let container = tv.textContainer,
                  t.location < (tv.string as NSString).length else { return }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: t.location, length: 1), actualCharacterRange: nil)
            let x = lm.boundingRect(forGlyphRange: glyphs, in: container).minX
            if abs(menus.anchorX - x) > 0.5 { menus.anchorX = x }
        }

        /// ↑ ↓ Return Tab Esc while the inline menu is open. Returns true when the menu took the key.
        func handleMenuKey(_ event: NSEvent) -> Bool {
            let menus = model.menus
            guard menus.isInlineOpen, textView?.hasMarkedText() != true else { return false }
            let f = event.modifierFlags.intersection([.shift, .command, .option, .control])
            switch event.keyCode {
            case 126: return menus.handleKey(.up)
            case 125: return menus.handleKey(.down)
            case 36, 76, 48: return f.isEmpty && menus.handleKey(.pick)
            case 53: return menus.handleKey(.escape)
            default: return false
            }
        }

        /// Re-applies attributes over the whole text (characters unchanged, so selection and undo are untouched).
        func restyle() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            plain = model.plainTextComposer
            let bold = ComposerMarkdownStyler.apply(to: storage, plain: plain, scale: scale, font: chatFont)
            tv.typingAttributes = ComposerMarkdownStyler.baseAttributes(scale: scale, font: chatFont)
            #if DEBUG || ANTICHAT_PERF_HARNESS
            if model.debugBoldRunCount != bold { model.debugBoldRunCount = bold }
            #else
            _ = bold
            #endif
            measure()
        }

        /// Called from layout passes: defer the model write out of the SwiftUI update.
        func scheduleMeasure() {
            guard !measureScheduled else { return }
            measureScheduled = true
            // A run-loop block (not a main-queue block) also runs when a caller already on the main queue spins
            // the run loop (tests, modal sessions).
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    self?.measureScheduled = false
                    self?.measure()
                }
            }
        }

        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
            // Keep the document as wide as the visible field (autoresizing from a zero-width start can lag).
            if let clip = tv.enclosingScrollView?.contentView, clip.bounds.width > 0,
               abs(tv.frame.width - clip.bounds.width) > 0.5 {
                tv.setFrameSize(NSSize(width: clip.bounds.width, height: tv.frame.height))
            }
            if abs(container.size.width - tv.frame.width) > 0.5 {
                container.size = NSSize(width: tv.frame.width, height: .greatestFiniteMagnitude)
            }
            lm.ensureLayout(for: container)
            let used = lm.usedRect(for: container).height
            let lines = max(1, Int((used / lineHeight).rounded()))
            let wraps = Self.wraps(tv.string, attributed: tv.attributedString(), width: singleRowWidth,
                                   currentLines: lines, currentWidth: container.size.width)
            if model.lineCount != lines { model.lineCount = lines }
            if model.textWraps != wraps { model.textWraps = wraps }
        }

        /// Would `string` take more than one line at the single-row width?
        static func wraps(_ string: String, attributed: NSAttributedString, width: CGFloat, currentLines: Int,
                          currentWidth: CGFloat) -> Bool {
            if string.isEmpty { return false }
            if string.contains(where: \.isNewline) { return true }
            guard width > 0 else { return currentLines > 1 }
            if abs(currentWidth - width) < 0.5 { return currentLines > 1 }
            if string.utf16.count > 1_000 { return true }  // never one line in any window; skip the measurement
            let w = attributed.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width
            return w > width
        }

        // MARK: Keys

        /// Return / ⇧Return / ⌘Return (step 4). Returns true when handled.
        func handleReturn(_ event: NSEvent) -> Bool {
            guard let tv = textView else { return false }
            let f = event.modifierFlags
            guard let action = model.keyAction(command: f.contains(.command), shift: f.contains(.shift),
                                               option: f.contains(.option), hasMarkedText: tv.hasMarkedText())
            else { return false }
            switch action {
            case .send:
                model.send()
            case .sendNow:  // M1.T19
                model.sendNow()
            case .insertNewline:
                tv.insertNewlineIgnoringFieldEditor(nil)
            }
            return true
        }

        /// Paste (step 6): > 10,000 characters become a card; otherwise plain text is inserted and restyled.
        /// M6.T01: file URLs (Finder copy) or an image on the pasteboard become file tiles instead.
        func handlePaste(from pasteboard: NSPasteboard) -> Bool {
            let files = PasteHandler.fileURLs(from: pasteboard)
            if !files.isEmpty {
                model.addFiles(files)
                return true
            }
            guard let s = pasteboard.string(forType: .string) else { return false }
            return model.handlePaste(s)
        }
    }
}

/// Re-measures when SwiftUI resizes the field (the bottom-row switch changes its width).
final class ComposerScrollView: NSScrollView {
    weak var coordinator: ComposerTextView.Coordinator?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5 || abs(newSize.height - frame.height) > 0.5
        super.setFrameSize(newSize)
        if changed { coordinator?.scheduleMeasure() }
    }
}

/// Q-015 r6: which ComposerNSTextView is a composer's current field. One ComposerModel can have two fields mounted at
/// once: the empty-state composer stays in the window during the dock animation (a removal transition) while the
/// docked one is already there. Only the newest field takes focus requests, and a focused field that leaves hands its
/// focus to the newest one.
@MainActor
enum ComposerFocusOwner {
    final class Ref { weak var view: ComposerNSTextView? }
    /// The newest field per composer (ComposerModel identity).
    private static var owners: [ObjectIdentifier: Ref] = [:]

    static func adopt(_ tv: ComposerNSTextView, for model: ComposerModel) {
        owners = owners.filter { $0.value.view != nil }
        let key = ObjectIdentifier(model)
        let ref = owners[key] ?? Ref()
        ref.view = tv
        owners[key] = ref
        tv.focusOwnerKey = key
    }

    /// True when `tv` is its composer's newest field (a field nobody adopted, e.g. a test's, always is).
    static func owns(_ tv: ComposerNSTextView) -> Bool {
        guard let key = tv.focusOwnerKey, let owner = owners[key]?.view else { return true }
        return owner === tv
    }

    /// `tv` (focused) is leaving `window`: once it is gone, its composer's current field in the same window takes the
    /// focus, unless a text field took it meanwhile (a rename field, search).
    static func handOff(from tv: ComposerNSTextView, in window: NSWindow) {
        guard let key = tv.focusOwnerKey, let next = owners[key]?.view, next !== tv else { return }
        // Never a weak reference to `window`: this runs from viewWillMove(toWindow: nil), also while the window itself is
        // being deallocated (its content view torn down), and forming a weak reference to a deallocating object aborts
        // the process ("Cannot form weak reference to instance … of class NSKVONotifying_NSWindow"). Its identity is
        // enough: the next field must still be in that same window.
        let windowID = ObjectIdentifier(window)
        RunLoop.main.perform { [weak next] in
            MainActor.assumeIsolated {
                guard let next, let window = next.window, ObjectIdentifier(window) == windowID, next.isEditable else { return }
                let fr = window.firstResponder
                if fr === next { return }
                if fr is NSText, !(fr is ComposerNSTextView) { return }  // a text field's editor: the user's choice
                window.makeFirstResponder(next)
            }
        }
    }
}

/// NSTextView with the composer's key and paste rules.
final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    /// The composer this field belongs to (ComposerFocusOwner, Q-015 r6).
    var focusOwnerKey: ObjectIdentifier?
    /// Where ⌘V reads from (tests use a private named pasteboard).
    var pasteboard: NSPasteboard = .general

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ComposerTextView.takeOverFocus(self) }
    }

    /// Q-015 r6: a focused field that leaves the window (the empty-state composer after the dock animation, a chat
    /// switch) hands the focus to its composer's current field in the same window. AppKit would give it to the window
    /// (and SwiftUI may move it on to the sidebar), so the docked field had no focus after the first send.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let w = window, w.firstResponder === self {
            ComposerFocusOwner.handOff(from: self, in: w)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    /// M1.T26a: the first focus of a visible composer ends `launchToUsable` (NFR-U1; once per process).
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { markUsableWhenVisible(tries: 300) }
        return ok
    }

    /// SwiftUI can focus the field before the window is on screen; usable = focused AND visible, so wait for both
    /// (polled every 5 ms for ≤ 1.5 s; the mark itself is once per process).
    private func markUsableWhenVisible(tries: Int) {
        guard window?.firstResponder === self else { return }
        if window?.isVisible == true {
            Signposts.markLaunchToUsable()
            AfterFirstFrame.usableFrameReached()  // M9.T05: the deferred launch services run after this frame
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in self?.markUsableWhenVisible(tries: tries - 1) }
        }
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleMenuKey(event) == true { return }  // M1.T17 inline menu
        if Self.isReturn(event), coordinator?.handleReturn(event) == true { return }
        super.keyDown(with: event)
    }

    /// ⌘Return reaches views as a key equivalent before keyDown; claim it only while this field has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isReturn(event), window?.firstResponder === self, event.modifierFlags.contains(.command),
           coordinator?.handleReturn(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if coordinator?.handlePaste(from: pasteboard) == true { return }
        guard pasteboard !== NSPasteboard.general, let s = pasteboard.string(forType: .string) else {
            pasteAsPlainText(sender)
            return
        }
        insertText(s, replacementRange: selectedRange())  // pasteAsPlainText reads only the general pasteboard
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { coordinator?.scheduleMeasure() }
    }
}

/// Inline Markdown styling for the composer source (step 5). Attributes only; markers stay visible but dimmed.
enum ComposerMarkdownStyler {
    static func paragraphStyle(scale: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let h = ComposerRules.lineHeight(scale: scale)
        p.minimumLineHeight = h
        p.maximumLineHeight = h
        return p
    }

    static func baselineOffset(for font: NSFont, scale: CGFloat) -> CGFloat {
        let natural = font.ascender - font.descender
        return max(0, (ComposerRules.lineHeight(scale: scale) - natural) / 2).rounded()
    }

    static func baseAttributes(scale: CGFloat, font chatFont: ChatFont = .default) -> [NSAttributedString.Key: Any] {
        let font = chatFont.nsFont(for: .body, scale: scale)
        return [
            .font: font,
            .foregroundColor: NSColor.textPrimary,
            .paragraphStyle: paragraphStyle(scale: scale),
            .baselineOffset: baselineOffset(for: font, scale: scale),
        ]
    }

    // Inline spans. Order matters: code first (its contents are not styled further), then bold, then italics.
    private static let codeRE = try! NSRegularExpression(pattern: "(`+)([^`\\n]+?)\\1")
    private static let boldRE = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicRE = try! NSRegularExpression(
        pattern: "(?<![\\*_\\w])([\\*_])(?=\\S)([^\\*_\\n]+?)(?<=\\S)\\1(?![\\*_\\w])")
    private static let listRE = try! NSRegularExpression(
        pattern: "^[ \\t]*([-*+]|\\d{1,9}[.)])[ \\t]", options: [.anchorsMatchLines])
    private static let headingRE = try! NSRegularExpression(
        pattern: "^(#{1,6})[ \\t]+(.+)$", options: [.anchorsMatchLines])
    private static let quoteRE = try! NSRegularExpression(pattern: "^>[ \\t]?", options: [.anchorsMatchLines])

    /// Resets `storage` to the base attributes and, unless `plain`, styles the Markdown spans.
    /// - Returns: the number of bold runs applied (the AT-002 leg 5 probe).
    @discardableResult
    static func apply(to storage: NSTextStorage, plain: Bool, scale: CGFloat, font chatFont: ChatFont = .default) -> Int {
        let whole = NSRange(location: 0, length: storage.length)
        let base = baseAttributes(scale: scale, font: chatFont)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(base, range: whole)
        guard !plain, storage.length > 0 else { return 0 }
        let s = storage.string
        let body = chatFont.nsFont(for: .body, scale: scale)
        let marker = NSColor.textTertiary
        var codeRanges: [NSRange] = []

        for m in codeRE.matches(in: s, range: whole) {
            let code = chatFont.nsFont(for: .code, scale: scale)
            storage.addAttributes([.font: code, .backgroundColor: NSColor.borderSubtle,
                                   .baselineOffset: baselineOffset(for: code, scale: scale)], range: m.range)
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
            let closing = NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length)
            storage.addAttribute(.foregroundColor, value: marker, range: closing)
            codeRanges.append(m.range)
        }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        var boldRuns = 0
        for m in boldRE.matches(in: s, range: whole) where !inCode(m.range) {
            storage.addAttribute(.font, value: chatFont.nsFont(for: .bodyEmph, scale: scale), range: m.range(at: 2))
            dimMarkers(storage, match: m, color: marker)
            boldRuns += 1
        }
        for m in italicRE.matches(in: s, range: whole) where !inCode(m.range) {
            storage.enumerateAttribute(.font, in: m.range(at: 2)) { value, r, _ in
                let f = (value as? NSFont) ?? body
                storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask), range: r)
            }
            dimMarkers(storage, match: m, color: marker)
        }
        for m in headingRE.matches(in: s, range: whole) {
            storage.addAttribute(.font, value: chatFont.nsFont(for: .bodyEmph, scale: scale), range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 1))
        }
        for m in listRE.matches(in: s, range: whole) {
            storage.addAttribute(.foregroundColor, value: NSColor.textSecondary, range: m.range(at: 1))
        }
        for m in quoteRE.matches(in: s, range: whole) {
            storage.addAttribute(.foregroundColor, value: marker, range: m.range)
        }
        return boldRuns
    }

    private static func dimMarkers(_ storage: NSTextStorage, match m: NSTextCheckingResult, color: NSColor) {
        let open = m.range(at: 1)
        storage.addAttribute(.foregroundColor, value: color, range: open)
        storage.addAttribute(.foregroundColor, value: color,
                             range: NSRange(location: NSMaxRange(m.range) - open.length, length: open.length))
    }
}
