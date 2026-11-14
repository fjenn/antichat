// Sticky tool chips (M1.T17 step 3; R-013 AC3; IS-6 "the chip persists for the next message", ChatGPT F-098).
// A picked tool becomes a chip; the chip stays after a send and is stored per chat in `chat.tools_json` (a JSON array
// of menu-item ids, e.g. `["web","tool:echo"]`) until its × removes it. The host (ChatSessions) loads a chat's chips
// when it is shown and saves them on every change, so a removal survives a relaunch.
// D-023 (a): chips whose item the active model cannot use (any tool entry while the starter is active) are not shown;
// they stay stored and come back when a model that takes tools is active.
import AntiChatHarness
import Foundation
import Observation

/// One chip: the menu item it came from.
public struct ToolChip: Sendable, Hashable, Identifiable {
    public let item: ComposerMenuItem
    public var id: String { item.id }

    public init(item: ComposerMenuItem) { self.item = item }
}

@MainActor
@Observable
public final class ToolChipsModel {
    /// Stored chip ids in the order they were picked (including ones not shown right now).
    public private(set) var ids: [String] = []
    /// What the menus offer now (`SlashCommandRegistry.menuItems`); chips resolve their title and state against it.
    public var available: [ComposerMenuItem] = []
    /// Called after every user change (pick, ×), with the new `tools_json` value (nil when empty).
    @ObservationIgnored public var onChange: (@MainActor (String?) -> Void)?

    public init() {}

    /// The chips to show: stored ids whose item is offered and usable now.
    /// M7.T03: a Web search chip stays while offline (state `.offline`, drawn as unavailable with `net.offlineShort`).
    /// The one-shot "Read this URL" chip (`readUrl`) is not a menu item; it is shown while `readURL` holds a URL.
    public var chips: [ToolChip] {
        ids.compactMap { id in
            if id == Self.readURLID, readURL != nil { return ToolChip(item: Self.readURLItem) }
            return available.first { $0.id == id && ($0.state.isEnabled || $0.state == .offline) && $0.makesChip }.map(ToolChip.init)
        }
    }

    // MARK: Read this URL (M7.T03 step 4)

    nonisolated public static let readURLID = "readUrl"
    nonisolated static let readURLItem = ComposerMenuItem(id: readURLID, kind: .tool(name: "read_url"), group: .add, state: .enabled,
                                              symbol: "link", name: nil)
    /// The pasted URL the suggestion / chip is about (nil = none).
    public private(set) var readURL: URL?
    /// The suggestion under the composer ("Read this URL") for the last pasted http(s) URL, until accepted or dismissed.
    public private(set) var readURLSuggestion: URL?

    /// The composer text changed: a pasted http(s) URL offers the suggestion (web search available only).
    public func noticeURL(in text: String, searchAvailable: Bool) {
        guard searchAvailable, readURL == nil else { if !searchAvailable { readURLSuggestion = nil }; return }
        let url = Self.firstWebURL(in: text)
        if url != readURLSuggestion { readURLSuggestion = url }
    }

    /// [Read this URL]: the chip forces `read_url` for the next send (the URL is fetched first).
    public func acceptReadURL() {
        guard let u = readURLSuggestion else { return }
        readURL = u
        readURLSuggestion = nil
        if !ids.contains(Self.readURLID) { ids.insert(Self.readURLID, at: 0) }  // first: it is the forced tool
    }

    /// After the send (one-shot) or the chip's ×.
    public func clearReadURL() {
        // fix/t05-u2-u5: every send calls this; an unconditional write re-evaluated the chip row each time.
        if readURL != nil { readURL = nil }
        if ids.contains(Self.readURLID) { ids.removeAll { $0 == Self.readURLID } }
    }

    public func dismissReadURLSuggestion() { readURLSuggestion = nil }

    nonisolated(unsafe) static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The first http(s) URL in `text` (NSDataDetector; `mailto:` and bare words excluded).
    nonisolated public static func firstWebURL(in text: String) -> URL? {
        let ns = text as NSString
        for m in urlDetector?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let u = m.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { continue }
            // Only what the user typed or pasted as a URL (with a scheme), not a bare "example.com".
            if ns.substring(with: m.range).lowercased().hasPrefix("http") { return u }
        }
        return nil
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Adds the chip for `item` (no duplicate). Returns false when the item makes no chip or is not usable.
    @discardableResult
    public func add(_ item: ComposerMenuItem) -> Bool {
        // M7.T03 (R-080 AC4; Q-015 r5): Web search picked while offline is a chip too (drawn `· Offline`, the reply says
        // it answered without the web). `chips` already showed an offline chip, but `add` refused one, so picking the
        // row offline did nothing.
        guard item.makesChip, item.state.isEnabled || item.state == .offline else { return false }
        // M7.T14: picking a tool's row turns it back on for this chat (drops its `tool.off:<group>` marker).
        let group: ToolGroup? = switch item.id { case "web": .web; case Self.imageChipID: .image; case "video": .video; default: nil }
        let unmarked = group.map { g in ids.contains(g.offMarker) } ?? false
        if unmarked, let group { ids.removeAll { $0 == group.offMarker } }
        if !ids.contains(item.id) || unmarked {
            if !ids.contains(item.id) { ids.append(item.id) }
            onChange?(toolsJSON)
        }
        return true
    }

    /// M7.T05: stores a non-chip marker (e.g. `hint:freshDismissed`) with the chat's chips (saved like a pick).
    public func addMarker(_ marker: String) {
        guard !ids.contains(marker) else { return }
        ids.append(marker)
        onChange?(toolsJSON)
    }

    /// The chip's ×. Removing Create image also drops its aspect (M4.T07).
    public func remove(_ id: String) {
        if id == Self.readURLID { clearReadURL(); return }
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id || (id == Self.imageChipID && $0.hasPrefix(Self.aspectPrefix)) }
        onChange?(toolsJSON)
    }

    // MARK: Aspect chips (M4.T07 step 2, R-030 AC2)

    nonisolated public static let imageChipID = "image"
    nonisolated public static let aspectPrefix = "aspect:"

    /// The Create image chip is present: the aspect chips show beside it.
    public var showsAspects: Bool { chips.contains { $0.id == Self.imageChipID } }

    /// The chosen aspect ("2:3"), stored with the chat's chips as `aspect:2:3` (persists per chat); nil = the model picks.
    public var aspect: String? {
        ids.first { $0.hasPrefix(Self.aspectPrefix) }.map { String($0.dropFirst(Self.aspectPrefix.count)) }
    }

    /// The ids a send carries: the shown chips, plus the chosen aspect while Create image is one of them. Q-015 r4: a
    /// send carried `chips` only, so the aspect pick (stored as `aspect:<ratio>`, not a chip) never reached the turn
    /// and every forced picture came out at the model's aspect (AT-030).
    public var turnIDs: [String] {
        let shown = chips.map(\.id)
        guard shown.contains(Self.imageChipID), let aspect else { return shown }
        return shown + [Self.aspectPrefix + aspect]
    }

    /// Picks `aspect` (one of `AspectChoice.all`); the same one again clears it.
    public func setAspect(_ aspect: String?) {
        let next = aspect == self.aspect ? nil : aspect
        ids.removeAll { $0.hasPrefix(Self.aspectPrefix) }
        if let next { ids.append(Self.aspectPrefix + next) }
        onChange?(toolsJSON)
    }

    /// Replaces the chips with a chat's stored value (no `onChange`: nothing to save).
    public func load(toolsJSON json: String?) { ids = Self.decode(json) }

    /// The `chat.tools_json` value of the stored chips, or nil when there are none.
    public var toolsJSON: String? { Self.encode(ids.filter { $0 != Self.readURLID }) }

    public static func encode(_ ids: [String]) -> String? {
        guard !ids.isEmpty, let data = try? JSONEncoder().encode(ids) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Ids from a `tools_json` value; anything that is not a JSON array of strings reads as no chips.
    public static func decode(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
