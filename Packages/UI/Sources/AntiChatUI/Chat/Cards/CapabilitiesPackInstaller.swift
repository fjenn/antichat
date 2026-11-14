// M2.T24 (R-238): the install cards' pack store = Settings › Capabilities' pack model (M2.T21), so a card and the
// PackRow show the same state and use the same Enable path (NFR-D2 disk rule → SetupInstaller queue). Harness sees it
// only as `PackInstalling` (injected at the composition root, architecture §3 rule 1).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import Foundation

public struct CapabilitiesPackInstaller: PackInstalling {
    public init() {}

    static func pack(_ p: MediaPack) -> ModelPack { p == .photo ? .photo : .video }

    public func availability(_ pack: MediaPack) async -> PackAvailability {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // `-FakePackState photo=ready|absent|downloading` (UI tests, the visual-QA probe; M4.T16): the install card path
        // sees the given state, ModelPack.shipped notwithstanding — before, only voice honoured it, so scripted media
        // turns hit "coming soon" and never reached create_image.
        if let fake = Self.fakeAvailability(LaunchOptions.current.fakePackStates[pack.rawValue]) { return fake }
        #endif
        let model = await MainActor.run { PackManagementModel.shared }
        if await MainActor.run(body: { model.selection == nil }) { await model.refresh() }
        return await MainActor.run {
            if pack == .video, let v = Self.videoIneligible(profile: model.profile, selection: model.selection, catalog: model.catalog) {
                return v
            }
            #if DEBUG || ANTICHAT_PERF_HARNESS
            // M5.T10 UI legs: the scripted video engine stands in for the (unshipped until M5.T14) Video pack.
            if pack == .video, InstalledVideoModels.scripted != nil { return .installed }
            #endif
            return Self.availability(model.state(Self.pack(pack)), installed: model.isInstalled(Self.pack(pack)))
        }
    }

    /// M5.T08 (R-040 AC4, R-046): a video request on a Mac that cannot run video gets the explanation card, whether
    /// or not this build ships Video yet (the reason is about the Mac, not the build). nil = eligible.
    static func videoIneligible(profile: HardwareProfile?, selection: Selection?, catalog: ModelCatalog?) -> PackAvailability? {
        guard let profile, let selection,
              let r = VideoEligibility.evaluate(profile: profile, selection: selection, catalog: catalog).reason else { return nil }
        switch r {
        case .needsMemory(let gb): return .videoNotEligible(gb: gb, ram: profile.ramGB)
        case .chipTooSlow:
            let s = r.copyText.string
            return .unavailable(reason: s.prefix(1).lowercased() + s.dropFirst())
        }
    }

    /// `-FakePackState` value → card availability (nil = not faked).
    static func fakeAvailability(_ value: String?) -> PackAvailability? {
        switch value {
        case "ready": .installed
        case "absent": .installable(bytes: 9_800_000_000, minutes: 10)
        case "downloading": .installing(percent: 42)
        default: nil
        }
    }

    /// PackRow state → card availability. "Needs 24 GB memory" reads "(needs 24 GB memory)" inside the sentence.
    @MainActor static func availability(_ s: PackRowState, installed: Bool) -> PackAvailability {
        switch s {
        case .comingSoon: return .comingSoon
        case .ready, .updateAvailable: return .installed
        case .notAvailable(let reason):
            let r = reason.string
            return .unavailable(reason: r.prefix(1).lowercased() + r.dropFirst())
        case .downloading(let percent, _, _, _): return .installing(percent: percent)
        case .notDownloaded(_, true): return .installing(percent: 0)
        case .notDownloaded(let bytes, false): return .installable(bytes: bytes, minutes: Self.minutes(bytes))
        case .checking: return .installing(percent: 100)
        case .off(let bytes): return installed ? .installed : .installable(bytes: bytes, minutes: Self.minutes(bytes))
        case .failed: return .installable(bytes: 0, minutes: 1)
        }
    }

    /// Onboarding's estimate: the assumed connection rate (`OnboardingModel.assumedBitsPerSecond`).
    @MainActor static func minutes(_ bytes: Int64) -> Int {
        max(1, Int((Double(bytes) * 8 / OnboardingModel.assumedBitsPerSecond / 60).rounded(.up)))
    }

    public func install(_ pack: MediaPack) async -> PackInstallStart {
        await MainActor.run {
            let model = PackManagementModel.shared
            let p = Self.pack(pack)
            model.enable(p)
            if let gb = model.diskShort[p] { return .diskShort(gbNeeded: gb) }
            return model.enabled.contains(p) ? .started : .failed
        }
    }
}
