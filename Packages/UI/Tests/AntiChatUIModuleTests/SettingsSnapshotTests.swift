// M1.T22 definition of done: snapshots of all 13 Settings section views (light/dark), plus the search results
// state, the Archived chats page and the Delete all sheet. Same rig as WindowSnapshotTests.
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=SettingsSnapshotTests.
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools
import Defaults
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SettingsSnapshotTests {
    static let size = CGSize(width: 820, height: 620)

    /// Settings › Voice without CoreAudio, the machine's voices or the microphone (M3.T08): two fixed input devices.
    /// Also pins General's power notices (no live machine state on any page).
    static func fixedVoiceHost(devices: [AudioInputDevice] = [AudioInputDevice(uid: "uid-built-in", name: "MacBook Pro Microphone"),
                                                               AudioInputDevice(uid: "uid-usb", name: "USB Audio")]) {
        VoiceSection.host = .init(devices: { AudioDeviceCatalog(provider: StaticAudioDeviceProvider(devices)) },
                                  systemVoices: { [("v1", "Samantha", "en-US"), ("v2", "Daniel", "en-GB"), ("v3", "Karen", "en-AU"),
                                                   ("v4", "Moira", "en-IE"), ("v5", "Rishi", "en-IN"), ("v6", "Tessa", "en-ZA")] },
                                  meterPermitted: { false }, micInUse: { false })
        // Settings › General › Performance: no notice, whatever this Mac's power source or thermal state is right now
        // (a full run's load can take it to serious: `power.cooler`).
        PerformancePicker.currentNotices = { [] }
    }

    @Test(arguments: SettingsSection.allCases)
    func section(_ section: SettingsSection) {
        SettingsKeys.resetAll()
        Self.fixedVoiceHost()
        // Storage: the same list on every Mac (no Release container hiding the shared folders).
        var paths = DataPaths.current()
        paths.keepsReleaseShared = false
        StorageModel.shared.pathsOverride = paths
        // VQ (S-21 Storage): fixed sizes (the test runner never measures this Mac), so the page shows its measured look.
        StorageModel.shared.report = section == .storage ? Self.storageFixture : nil
        // Capabilities' "Free on disk" footer: a fixed figure, never this Mac's live free space (78 vs 108 GB seen).
        PackManagementModel.shared.debugFreeBytes(78_000_000_000)
        defer { StorageModel.shared.pathsOverride = nil; StorageModel.shared.report = nil
                PackManagementModel.shared.debugFreeBytes(nil) }
        let model = SettingsModel()
        model.open(section)
        // M7.T12: the Skills page gets its own library (the five starters in a temp store), never the shared one
        let skills = section == .skills ? Self.pinnedSkills() : nil
        assertLooks("settings-\(section.rawValue)", size: Self.size, window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model).environment(\.skillsLibrary, skills))
    }

    static let storageFixture = StorageReport(
        bytes: [.chatModels: 5_400_000_000, .voice: 620_000_000, .photo: 3_100_000_000, .chats: 48_000_000, .media: 210_000_000,
                .caches: 95_000_000],
        total: 9_473_000_000, models: [], freeBytes: 182_000_000_000, measuredAt: Date(timeIntervalSince1970: 0),
        locations: [.library: 258_000_000, .models: 9_120_000_000, .caches: 88_000_000, .logs: 7_000_000, .preferences: 40_000])

    /// M7.T12: Settings → Skills shows a fixed store (the starter skills in a temp folder over an in-memory database).
    /// Per test, not observing other suites' change posts (an empty Skills page was seen once with the shared one).
    static func pinnedSkills() -> SkillsLibrary? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-skills-\(UUID().uuidString)", isDirectory: true)
        guard let db = try? AppDatabase.inMemory() else { return nil }
        let store = SkillStore(root: dir, database: db)
        _ = try? StarterSkills.installIfNeeded(into: store)
        return SkillsLibrary(observe: false, store: { store })
    }

    /// M3.T08 (R-053 AC1): no input devices → "No devices found", the meter and the picker disabled.
    @Test func voiceNoDevices() {
        SettingsKeys.resetAll()
        Self.fixedVoiceHost(devices: [])
        defer { Self.fixedVoiceHost() }
        let model = SettingsModel()
        model.open(.voice)
        assertLooks("settings-voice-noDevices", size: Self.size, window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model))
    }

    @Test func searchResults() {
        Self.fixedVoiceHost()
        let model = SettingsModel()
        model.query = "archive"
        assertLooks("settings-search-archive", size: Self.size, window: true, converge: true,
                    SettingsRootView(context: SettingsContext(chats: nil), model: model))
    }

    @Test func archivedChatsPage() throws {
        let chats = try ChatListService.inMemory()
        for title in ["Trip to Lisbon", "Tax return 2025", "Sourdough starter"] { _ = try chats.create(title: title) }
        try chats.archiveAll(now: Date(timeIntervalSince1970: 1_790_000_000))  // fixed date in the rows
        assertLooks("settings-archived-page", size: CGSize(width: 560, height: 460), converge: true,
                    ArchivedChatsPage(chats: chats, onDone: {}))
    }

    @Test func deleteAllSheet() {
        // Fixed at the reference size: the fitted height came out 186 or 187 pt under parallel load (flake, twice).
        assertLooks("settings-delete-all", size: CGSize(width: 420, height: 186), converge: true, DeleteAllSheet(onDelete: {}, onCancel: {}))
    }
}
}  // extension WindowSuites
