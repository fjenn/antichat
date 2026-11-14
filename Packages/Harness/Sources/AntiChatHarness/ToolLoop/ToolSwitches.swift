// M7.T14 steps 3, 5, 6 (R-268 AC1–AC3; settings-map §7): the built-in tool groups of Settings → Tools & Connections,
// their global on/off switches, the per-chat overrides and the Tool access mode.
//   - Global switches live in the app's settings store (the `-DefaultsSuite` suite in DEBUG probes, like
//     NetworkPolicyStore), under the same names as the UI's `Defaults.Keys`: `toolImage`, `toolVideo`, `toolMemory`,
//     `toolAccess` (M7.T14) and M6.T19's `createFilesEnabled` / `runCodeEnabled` (ToolDefaults; FileToolsTools also
//     unregisters those tools when off). Web search has no key here: its global switch is the gate's `.search`
//     category (NetworkPolicyStore), and connections keep theirs (server / tool rows, M7.T06).
//   - A per-chat change is a marker in `chat.tools_json` (`tool.on:<group>` / `tool.off:<group>`, like the skill and
//     connection markers) and never writes the global store (R-268 AC2).
//   - Tool access (R-268 AC3): `whenNeeded` (default) lets ToolSelector pick per message; `all` offers every enabled
//     tool (still Block-, offline- and switch-gated, and bounded by the tier's schema token cap).
import AntiChatFoundation
import AntiChatTools
import Foundation

/// One row of the Tools page's built-in list and of "+" → Tools ›.
public enum ToolGroup: String, Sendable, CaseIterable, Hashable {
    case web, image, video, files, code, memory

    /// The registry tools the switch covers (a name not registered on this Mac is simply absent).
    public var tools: [String] {
        switch self {
        case .web: ["web_search", "read_url"]
        case .image: ["create_image", "edit_image"]
        case .video: ["create_video"]
        case .files: ["create_document", "create_spreadsheet", "create_presentation", "create_chart", "export_table"]
        case .code: [RunPythonTool.name]  // M6 File tools sandbox (R-018)
        case .memory: ["memory"]
        }
    }

    /// The row's title (copy deck §9).
    public var copyKey: String {
        switch self {
        case .web: "set.tools.web"
        case .image: "set.tools.image"
        case .video: "set.tools.video"
        case .files: "set.tools.createFiles"
        case .code: "set.tools.code"
        case .memory: "set.tools.memory"
        }
    }

    /// The settings key of the global switch (nil = Web search, whose switch is the gate's `.search` category).
    public var defaultsKey: String? {
        switch self {
        case .web: nil
        case .image: "toolImage"
        case .video: "toolVideo"
        case .files: ToolDefaults.createFilesEnabled
        case .code: ToolDefaults.runCodeEnabled
        case .memory: "toolMemory"
        }
    }

    /// The global default (settings-map §7: on when the pack / feature is installed; Run code off until installed).
    public var defaultOn: Bool { self != .code }

    public var symbol: String {
        switch self {
        case .web: "globe"
        case .image: "photo"
        case .video: "film"
        case .files: "doc"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .memory: "brain"
        }
    }

    public static func group(ofTool name: String) -> ToolGroup? { allCases.first { $0.tools.contains(name) } }

    public var onMarker: String { "tool.on:\(rawValue)" }
    public var offMarker: String { "tool.off:\(rawValue)" }
}

/// Settings → Tools & Connections → Tool access (R-268 AC3).
public enum ToolAccess: String, Sendable, CaseIterable, Hashable {
    case whenNeeded, all

    public static let defaultsKey = "toolAccess"
    public static let `default` = ToolAccess.whenNeeded

    /// `set.tools.access.allWarn` shows next to "Always offer all" on T0–T2 only.
    public static func warns(_ tier: DeviceTier) -> Bool { tier == .t0 || tier == .t1 || tier == .t2 }
}

public final class ToolSwitches: @unchecked Sendable {
    /// The app's switches (the `-DefaultsSuite` suite in DEBUG probes, else the app domain).
    public static let shared = ToolSwitches(defaults: {
        AppDefaults.launchSuite ?? AppDefaults.standard  // a DEBUG test process: its own store, not the shared tool domain
    }())

    /// Posted after a global change made through this type (the UI's Defaults writes post it too, via `notify`).
    public static let didChange = Notification.Name("AntiChatToolSwitchesDidChange")

    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The global switch of `group` (Web search: always true here; its switch is the gate's `.search` category).
    public func isOn(_ group: ToolGroup) -> Bool {
        guard let key = group.defaultsKey else { return true }
        return defaults.object(forKey: key) == nil ? group.defaultOn : defaults.bool(forKey: key)
    }

    public func setOn(_ group: ToolGroup, _ on: Bool) {
        guard let key = group.defaultsKey else { return }
        defaults.set(on, forKey: key)
        Self.notify()
    }

    /// Whether `group` is on in a chat whose `chat.tools_json` ids are `ids`: the chat's override, else the global
    /// switch.
    public func isOn(_ group: ToolGroup, chatToolIDs ids: [String]) -> Bool {
        if ids.contains(group.offMarker) { return false }
        if ids.contains(group.onMarker) { return true }
        return isOn(group)
    }

    /// Whether registry tool `name` passes the switches in that chat (tools outside the groups always pass).
    public func allows(_ name: String, chatToolIDs ids: [String]) -> Bool {
        guard let g = ToolGroup.group(ofTool: name) else { return true }
        return isOn(g, chatToolIDs: ids)
    }

    public var access: ToolAccess {
        get { defaults.string(forKey: ToolAccess.defaultsKey).flatMap(ToolAccess.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: ToolAccess.defaultsKey); Self.notify() }
    }

    public static func notify() { NotificationCenter.default.post(name: didChange, object: nil) }
}
