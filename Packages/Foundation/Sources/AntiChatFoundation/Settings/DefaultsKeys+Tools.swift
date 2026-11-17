import Foundation

public enum ToolDefaults {
    public static let createFilesEnabled = "createFilesEnabled"
    public static let runCodeEnabled = "runCodeEnabled"
    public static let allowNetworkForCode = "allowNetworkForCode"
    public static let runtimeDidChangeNotification = "AntiChatRuntimeInstallerDidChange"

    nonisolated(unsafe) public static let store: UserDefaults = {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let suite = AppDefaults.launchSuite { return suite }
        #endif
        return AppDefaults.standard  // a DEBUG test process: its own store, not the shared tool domain
    }()

    public static func registerDefaults() {
        store.register(defaults: [createFilesEnabled: true, runCodeEnabled: false, allowNetworkForCode: true])
    }

    public static func bool(_ key: String) -> Bool { store.bool(forKey: key) }
    public static func set(_ value: Bool, _ key: String) { store.set(value, forKey: key) }
}
