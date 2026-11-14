// M2.T18 steps 1–2 (S-00): the onboarding window and its gate. Borderless full-size content, 1280 × 800 default,
// resizable ≥ 960 × 640, centred, always dark. Shown while `onboarding.completed` is false (or `-ResetOnboarding YES`);
// `-SkipOnboarding YES` and the in-process probes / harnesses keep the M1 path. Before step 1, off the main thread
// (≤ 1 s, no network): the hardware probe, the catalog (cached or bundled baseline) and the free disk.
import AntiChatDesign
import AntiChatFoundation
import AntiChatNetwork
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI

public enum OnboardingGate {
    public static let completedKey = "onboarding.completed"

    public static func shouldShow(options: LaunchOptions = .current, defaults: UserDefaults = AppDefaults.standard) -> Bool {
        if options.skipOnboarding { return false }
        if options.resetOnboarding { return true }
        // Test / probe launches keep the M1 window (they drive it in-process).
        let probes: [String?] = [options.uiProbe, options.paletteProbe, options.rendererProbe, options.contextProbe,
                                 options.settingsProbe, options.appearanceProbe, options.shortcutsProbe, options.turnProbe,
                                 options.incognitoProbe, options.draftProbe, options.modelInfoProbe, options.menusProbe,
                                 options.composerHarness, options.finalAcceptanceProbe]
        if probes.contains(where: { $0 != nil }) { return false }
        // Scripted-engine / dev-container / perf launches are test runs (they pass -ResetOnboarding YES to see it).
        if options.scriptedEngineScript != nil || options.devContainer != nil
            || ProcessInfo.processInfo.environment["ANTICHAT_PERF_QUIT_AFTER"] != nil { return false }
        return !defaults.bool(forKey: completedKey)
    }

    public static func markCompleted(defaults: UserDefaults = AppDefaults.standard) { defaults.set(true, forKey: completedKey) }
}

@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    public static var current: OnboardingWindowController?

    public let model: OnboardingModel
    public let window: NSWindow
    private var observers: [NSObjectProtocol] = []

    /// Shows onboarding over the app (the main windows are hidden until it finishes). `onDone` runs after the last step.
    @discardableResult
    public static func present(database: AppDatabase, evilStep: ((OnboardingModel) -> AnyView)? = nil,
                               onDone: @escaping () -> Void) -> OnboardingWindowController {
        let c = OnboardingWindowController(model: makeModel(database: database), evilStep: evilStep, onDone: onDone)
        current = c
        return c
    }

    /// Catalog (cached / baseline), free disk and the blobs in the store now; the hardware profile lands when the probe
    /// returns (the card area shows `onb.hardware.probing` until then).
    static func makeModel(database: AppDatabase) -> OnboardingModel {
        let models = DownloadsLaunch.models
        let blobs = BlobStore(models: models)
        let catalog = CatalogLaunch.shared?.catalog ?? CatalogStore.bundledBaseline().flatMap { try? ModelCatalog.decode($0.data) }
        let model = OnboardingModel(profile: nil, catalog: catalog, freeBytes: DiskPreflight.freeBytes(volume: models.root),
                                    online: !PathStatus.shared.isOffline, present: { blobs.contains($0) })
        // M2.T20 (DoD): a relaunch mid-onboarding resumes at step 4 with the downloads continuing.
        // `-ResetOnboarding YES` is a first run: it starts at step 1, never at a saved step 4.
        let resume = LaunchOptions.current.resetOnboarding ? nil : SetupChoice.load()
        Task.detached(priority: .userInitiated) {
            let p = await HardwareProbe.shared.current(database: database, dataRoot: AppBootstrap.dataRoot)
            await MainActor.run {
                model.update(profile: p, catalog: CatalogLaunch.shared?.catalog ?? catalog)
                if let resume, let c = model.catalog {
                    model.resume(packs: resume.packSet, evil: resume.evil)
                    SetupLaunch.resume(choice: resume, profile: p, catalog: c)
                }
            }
        }
        // M2.T20: the first-run install (starter first, Evil after every Normal set) through the app's coordinator.
        model.onInstall = { [weak model] plan in
            SetupLaunch.begin(plan: plan, packs: model?.chosenPacks ?? [.chat])
        }
        // M2.T19: consent (ConsentStore, same path as Settings) + the Evil variants queued after every Normal set.
        model.onEvilAccepted = { plan in
            do { try EvilModeModel.shared?.enable(adultSelfDeclared: true) } catch {
                AppLog.log(.ui, .error, "onboarding: Evil consent failed: \(error)")
            }
            SetupLaunch.addEvil(plan)
        }
        model.onEvilDeclined = { SetupLaunch.withdrawEvil(EvilModeModel.shared) }
        model.onRetry = { SetupLaunch.retry() }
        // Step 4 WebSearchSwitch → the `search` category default (T03; the search tool lands in M7).
        model.searchOn = NetworkPolicyStore.shared.storedValue(.search)
        model.onSearchChanged = { NetworkPolicyStore.shared.setEnabled(.search, $0) }
        return model
    }

    init(model: OnboardingModel, evilStep: ((OnboardingModel) -> AnyView)?, onDone: @escaping () -> Void) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: 960, height: 640)
        window.isRestorable = false
        window.delegate = self
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        // M9.T03: the window and its hosting group are named (the title is hidden, so both were unnamed, S-01 audit).
        window.contentView = NSHostingView(rootView: OnboardingFlow(model: model, evilStep: evilStep?(model))
            .windowAccessibilityTitle(CopyKey("a11y.onboarding").string()))
        window.center()
        model.onFinish = { [weak self] in
            SetupLaunch.finish()
            OnboardingGate.markCompleted()
            StarterSuggestions.onboardingFinished(packs: model.chosenPacks)
            self?.window.orderOut(nil)
            OnboardingWindowController.current = nil
            onDone()
        }
        observers.append(NotificationCenter.default.addObserver(forName: PathStatus.didChange, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated { model?.online = !PathStatus.shared.isOffline }
        })
        observers.append(NotificationCenter.default.addObserver(forName: CatalogStore.didChange, object: nil, queue: .main) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model, let c = CatalogLaunch.shared?.catalog else { return }
                model.update(profile: model.profile, catalog: c)
            }
        })
        BackgroundRun.makeKeyAndOrderFront(window)
    }

    public func windowWillClose(_ notification: Notification) {
        // Closing onboarding quits (nothing is usable before Chat exists); the next launch shows it again.
        NSApp.terminate(nil)
    }
}
