// M3.T04 (R-281; app side of VoiceBackendSelector): what voice this Mac offers right now.
// - `packState`: the Voice pack — `ready` once installed and verified (enabled packs, `-FakeVoiceInstalled`), else
//   `absent` / `downloading` (`-FakePackState voice=…`; a DEBUG app flips it at runtime with `TestHooks.setPackState`).
//   Only a ready pack's models are registered with the helper, so a session started before it verifies stays Basic.
// - `basic`: Basic dictation through the system's on-device SpeechTranscriber — `ready` when the locale's assets are
//   installed; `installable` when supported and Offline only is off (the click asks the system to install them,
//   Apple-managed, outside NetworkGate); `unavailable` otherwise → the MicButton shows the Voice pack install card.
//   Basic read aloud (AVSpeechSynthesizer) is always there.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import Observation
import Speech

@MainActor
@Observable
public final class VoiceAvailability {
    public enum PackState: String, Sendable { case absent, downloading, ready }
    public enum BasicState: Sendable, Equatable { case checking, ready, installable, unavailable }

    public static let shared = VoiceAvailability()

    public private(set) var packState: PackState
    public private(set) var basic: BasicState = .checking

    init(options: LaunchOptions = .current) {
        if let fake = options.fakePackStates["voice"].flatMap(PackState.init(rawValue:)) {
            packState = fake
        } else {
            packState = options.fakeVoiceInstalled || SuggestionProvider.enabledPacks().contains(.voice) ? .ready : .absent
        }
        #if DEBUG || ANTICHAT_PERF_HARNESS
        TestHooks.observePackState { [weak self] pack, state in
            guard pack == "voice", let s = PackState(rawValue: state) else { return }
            self?.setPackState(s)
        }
        #endif
        Task { await refreshBasic() }
    }

    public var packReady: Bool { packState == .ready }
    /// Dictation can start (full or Basic) without the install card.
    public var canDictate: Bool { packReady || basic == .ready || basic == .installable }

    public func setPackState(_ s: PackState) { packState = s }

    public func refreshBasic() async {
        basic = await Self.basicState(offlineOnly: NetworkPolicyStore.shared.offlineOnly)
    }

    nonisolated static func basicState(offlineOnly: Bool, locale: Locale = .current) async -> BasicState {
        guard SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unavailable }
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == l.identifier(.bcp47) }) { return .ready }
        let t = SpeechTranscriber(locale: l, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return .ready
        case .supported, .downloading: return offlineOnly ? .unavailable : .installable
        default: return .unavailable
        }
    }

    /// `installable` → asks the system to install the on-device model (the user clicked the mic).
    public func installBasic() async -> Bool {
        guard basic == .installable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return basic == .ready }
        let t = SpeechTranscriber(locale: l, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await request.downloadAndInstall() }
        } catch {
            AppLog.log(.voice, .error, "Basic voice assets: \(error)")
        }
        await refreshBasic()
        return basic == .ready
    }

    /// The helper's model set for a session starting now (VoiceBackendSelector: nothing until the pack is ready).
    public func registeredModels(installed: VoiceModelSet) -> VoiceModelSet {
        packReady ? installed : VoiceModelSet(requestID: installed.requestID, slots: [:])
    }
}

#if DEBUG || ANTICHAT_PERF_HARNESS
/// Test hooks a running DEBUG app accepts from XCUITests / probes (distributed notifications; nothing in Release).
public enum TestHooks {
    public static let packStateNotification = Notification.Name("app.antichat.test.setPackState")

    /// Flips a pack's state in the running app: `TestHooks.setPackState("voice", "ready")` from a test process.
    public static func setPackState(_ pack: String, _ state: String) {
        DistributedNotificationCenter.default().postNotificationName(packStateNotification, object: "\(pack)=\(state)",
                                                                     userInfo: nil, deliverImmediately: true)
    }

    /// The running app only: a unit-test process never listens, since the notification is Mac-wide (a flip posted for
    /// one app would change another process's Voice pack state, and with it the Settings › Voice picker).
    @MainActor static func observePackState(_ f: @escaping @MainActor (String, String) -> Void) {
        guard !AppDefaults.isTestProcess() else { return }
        _ = DistributedNotificationCenter.default().addObserver(forName: packStateNotification, object: nil, queue: .main) { n in
            let kv = (n.object as? String)?.split(separator: "=").map(String.init) ?? []
            guard kv.count == 2 else { return }
            MainActor.assumeIsolated { f(kv[0], kv[1]) }
        }
    }
}
#endif
