// SidePanel model (M4.T11 steps 1, 3, 4; components §4 "SidePanel (Artifacts)": opening 320 ms, open, resizing,
// closed). Holds the open artifact, its version chain (artifact_version rows, oldest first), the remembered width
// per window, and the current text selection for "Edit selection".
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Foundation
import UniformTypeIdentifiers

public struct PanelVersion: Equatable, Sendable, Identifiable {
    public var id: Int { n }
    public let n: Int
    public let url: URL
    public init(n: Int, url: URL) { self.n = n; self.url = url }
}

/// What the panel body shows for a file.
public enum PanelBody: Equatable, Sendable {
    case pdf, image, web, text, quickLook

    /// The body for a file: M6.T13 web previews by extension first (jsx / tsx → React, mmd → Mermaid, .vl.json → Vega).
    public init(url: URL) {
        if PreviewMode(url: url) != nil { self = .web } else { self.init(UTType(filenameExtension: url.pathExtension) ?? .data) }
    }

    public init(_ type: UTType) {
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .svg) || type.conforms(to: .html) { self = .web }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .commaSeparatedText) || type.conforms(to: .tabSeparatedText)
                    || type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
                    || type.identifier == "net.daringfireball.markdown" { self = .text }
        else { self = .quickLook }
    }

    /// Bodies whose text can be selected for "Edit selection" (documents; image regions come with M4.T15).
    public var supportsTextSelection: Bool { self == .pdf || self == .text }
}

@MainActor
@Observable
public final class SidePanelModel {
    public static let minWidth: CGFloat = 320
    public static let maxWidth: CGFloat = 900
    public static let defaultWidth: CGFloat = 480
    /// Opening animation (components §4); none under Reduce Motion.
    public static let openDuration: Double = 0.32

    public private(set) var title: String = ""
    public private(set) var versions: [PanelVersion] = []
    public private(set) var currentIndex: Int = 0
    public var isOpen = false
    public private(set) var width: CGFloat
    /// The text selected in the body (PDF / text), trimmed; empty when nothing is selected.
    public var selection: String = ""
    /// M7.T03 step 8: the panel shows a reply's web sources (SourcesPanel) instead of a file.
    public private(set) var sources: SourcesContent?

    /// Called after a version switch so the in-turn card can follow (M4.T11 step 3).
    @ObservationIgnored public var onVersionChange: ((PanelVersion) -> Void)?
    /// "Edit selection": the host prefills the composer with this text (M4.T11 step 4).
    @ObservationIgnored public var onEditSelection: ((String) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let widthKey: String

    /// `windowID` keys the remembered width ("remembers width per window").
    public init(windowID: String = "main", defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
        self.widthKey = "sidePanel.width.\(windowID)"
        let stored = defaults.double(forKey: widthKey)
        self.width = stored > 0 ? Self.clamp(stored) : Self.defaultWidth
    }

    static func clamp(_ w: CGFloat) -> CGFloat { min(max(w, minWidth), maxWidth) }

    public var current: PanelVersion? { versions.indices.contains(currentIndex) ? versions[currentIndex] : nil }

    public var contentType: UTType {
        let ext = ((current?.url.pathExtension).flatMap { $0.isEmpty ? nil : $0 }) ?? (title as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    public var body: PanelBody {
        if preview != nil { return .web }
        if let url = current?.url { return PanelBody(url: url) }
        return PanelBody(contentType)
    }

    // MARK: M6.T13 artifacts (R-016 AC2–AC4, R-277 AC1)

    /// The artifact shown (promoted block or produced file), nil for an attachment or a plain file.
    public private(set) var artifactID: String?
    /// The fence language of a promoted block (Fix / Edit selection send it back in the same fence).
    public private(set) var language: String = ""
    /// The web preview mode (React / Mermaid / Vega / HTML / SVG); nil = from the file extension.
    public private(set) var preview: PreviewMode?
    /// The page a PDF opens on (M6.T02 page pills; 1-based).
    public private(set) var page: Int?
    /// The preview's last JavaScript error (`previewError` handler): shows `panel.fix`.
    public var previewError: String?
    /// The Edit selection popover is up.
    public var editingSelection = false
    /// Edit selection / Fix on an artifact → a follow-up turn (the host sends it; nil = prefill only).
    @ObservationIgnored public var onArtifactEdit: ((ArtifactEditRequest) -> Void)?

    /// The preview mode for the current version.
    public var previewMode: PreviewMode? { preview ?? current.flatMap { PreviewMode(url: $0.url) } }

    /// Sets the preview mode of what is open (a produced file whose extension does not say it, e.g. a Vega-Lite .json).
    public func setPreview(_ mode: PreviewMode?) { preview = mode }

    /// Opens a promoted artifact on `ref.version` (its chain in the picker).
    public func open(_ ref: PromotedArtifactRef) {
        open(title: ref.title, versions: ref.versions.map { PanelVersion(n: $0.n, url: URL(fileURLWithPath: $0.path)) },
             selecting: ref.version)
        artifactID = ref.artifactID
        language = ref.language
        preview = PreviewMode(kind: ref.kind, react: ref.react, language: ref.language)
    }

    /// Opens a PDF at `page` (1-based).
    public func open(pdf url: URL, title: String? = nil, page: Int) {
        open(file: url, title: title)
        self.page = page
    }

    /// The current version's text (artifact source; empty for binary files).
    public var currentSource: String {
        current.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
    }

    /// `panel.fix`: "Fix this error in <title>: <message>" with the artifact → its next version.
    public func fix() {
        guard let artifactID, let message = previewError, let onArtifactEdit else { return }
        onArtifactEdit(ArtifactEditRequest(artifactID: artifactID, title: title, language: language, source: currentSource,
                                           action: .fix(message: message), baseVersion: current?.n))
        previewError = nil
    }

    /// Edit selection on an artifact: the popover's instruction → its next version. Without an artifact (an attached
    /// PDF, a plain file) the composer is prefilled with the quote instead.
    public func submitEditSelection(instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        editingSelection = false
        guard canEditSelection else { return }
        guard let artifactID, let onArtifactEdit, !text.isEmpty else {
            editSelection()
            return
        }
        onArtifactEdit(ArtifactEditRequest(artifactID: artifactID, title: title, language: language, source: currentSource,
                                           action: .editSelection(selection: selection, instruction: text),
                                           baseVersion: current?.n))
    }

    /// Edit selection opens the instruction popover on an artifact; elsewhere it prefills the composer.
    public var editsInPlace: Bool { artifactID != nil && onArtifactEdit != nil }

    /// "Version {current} of {total}"; nil for a single version.
    public var versionLabel: CopyText? {
        guard versions.count > 1, let current else { return nil }
        return CopyText(CopyKey("panel.version"), ["current": String(current.n), "total": String(versions.count)])
    }

    /// Opens on the latest version unless `selecting` names one.
    public func open(title: String, versions: [PanelVersion], selecting n: Int? = nil) {
        guard !versions.isEmpty else { return }
        sources = nil
        self.title = title
        self.versions = versions.sorted { $0.n < $1.n }
        currentIndex = n.flatMap { want in self.versions.firstIndex { $0.n == want } } ?? self.versions.count - 1
        selection = ""
        artifactID = nil
        language = ""
        preview = nil
        page = nil
        previewError = nil
        editingSelection = false
        isOpen = true
    }

    public func open(file url: URL, title: String? = nil) {
        open(title: title ?? url.lastPathComponent, versions: [PanelVersion(n: 1, url: url)])
    }

    @ObservationIgnored private var autoOpened: Set<URL> = []

    /// M6.T13: true the first time a produced file asks to auto-open the panel (one open per file and window).
    public func autoOpenOnce(_ url: URL?) -> Bool {
        guard let url, !autoOpened.contains(url) else { return false }
        autoOpened.insert(url)
        return true
    }

    /// M7.T03: the reply's sources (title `search.sources`).
    public func openSources(_ content: SourcesContent) {
        guard !content.all.isEmpty else { return }
        title = CopyKey("search.sources").string()
        versions = []
        currentIndex = 0
        selection = ""
        sources = content
        isOpen = true
    }

    public func close() {
        isOpen = false
        selection = ""
        editingSelection = false
    }

    /// A new version of the open artifact arrived (Fix / Edit selection reply): the panel switches to it.
    public func follow(_ ref: PromotedArtifactRef) {
        guard isOpen, ref.artifactID == artifactID, ref.versions.count > versions.count else { return }
        open(ref)
    }

    public func select(version n: Int) {
        guard let index = versions.firstIndex(where: { $0.n == n }), index != currentIndex else { return }
        currentIndex = index
        selection = ""
        previewError = nil
        onVersionChange?(versions[index])
    }

    /// The conversation keeps at least this much beside the panel (the composer and bubbles stay usable).
    public static let minChatWidth: CGFloat = 480
    /// VQ-M10 round 65 (S-15): opening the panel collapses the sidebar when the conversation beside it would be
    /// narrower than this (WindowState.sidePanelChanged).
    public static let comfortableChatWidth: CGFloat = 640

    /// The width drawn in a container `container` wide: the remembered width, but never so wide that the conversation
    /// gets less than `minChatWidth` (at most half the container on a narrow window). A remembered 766 pt panel in a
    /// 1180 pt window pushed the split view past the window edges and squeezed the composer to 0 pt (Q-015 r2).
    public func shownWidth(in container: CGFloat) -> CGFloat {
        guard container.isFinite, container > 0 else { return width }
        return min(width, max(container - Self.minChatWidth, container / 2))
    }

    public func resize(to w: CGFloat) {
        width = Self.clamp(w)
        defaults.set(Double(width), forKey: widthKey)
    }

    public var canEditSelection: Bool { body.supportsTextSelection && !selection.isEmpty }

    /// The composer prefill: the selection as a Markdown quote, then an empty line for the instruction.
    public static func editPrompt(for selection: String) -> String {
        let quoted = selection.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return quoted + "\n\n"
    }

    public func editSelection() {
        guard canEditSelection else { return }
        onEditSelection?(Self.editPrompt(for: selection))
    }

    /// The version chain of an artifact as panel versions; `resolve` maps a blob id to its file (media store).
    public static func versions(of artifactID: String, in repository: ArtifactRepository,
                                resolve: (String) -> URL?) throws -> [PanelVersion] {
        try repository.versions(artifactID: artifactID).compactMap { v in resolve(v.blobID).map { PanelVersion(n: v.n, url: $0) } }
    }
}
