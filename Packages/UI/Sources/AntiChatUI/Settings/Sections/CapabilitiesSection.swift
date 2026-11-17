// Settings → Capabilities (settings-map §3; R-100 AC4): the packs (M2.T21: PackRow per pack, DisablePackSheet; the
// Images and Video packs are also the switches for creating images and video) with Evil as the fifth row of the same
// list (owner 2026-11-16: its switch runs the 18+ sheet and the download; hidden with ff.evilMode off), the Tools
// switches (ToolRows: Web search, Create files, Analyse data, Memory), Voice (microphone, voice), Evil Mode's own
// options once it is on (EvilSettingsPanel, no second switch) and the **Advanced** group, collapsed by default: the models (their own closed group: model per
// pack × mode), keep-loaded, memory budget, video options (M2.T07, AdvancedSection), the starter model, the tools'
// and the voice's finer options, Recent recordings.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import AntiChatStorage
import Defaults
import SwiftUI

struct CapabilitiesSection: View {
    @Bindable var model: SettingsModel
    var database: AppDatabase?
    @Default(.showModelInfo) private var showModelInfo
    /// M2.T21: the pack rows' live state.
    var packs: PackManagementModel = .shared
    @State private var disabling: ModelPack?
    @State private var confirmStarter = false
    /// Snapshots pin their own Evil Mode model; the app's is `EvilModeModel.shared`.
    @Environment(\.settingsEvilModel) private var pinnedEvil
    private var evil: EvilModeModel? {
        FeatureFlag.evilMode.isEnabled(.antichat) ? pinnedEvil ?? EvilModeModel.shared : nil
    }

    var body: some View {
        CatalogStatusBanner(store: CatalogLaunch.shared)
        ModelUpdateRows(status: ModelUpdatesLaunch.status)
        Section {
            // M2.T21 (R-202 AC1): Chat (locked on) + Voice, Photo, Video.
            ForEach(ModelPack.allCases, id: \.self) { pack in
                PackRow(pack: pack, state: packs.state(pack),
                        isOn: pack == .chat || packs.isOn(pack), diskShortGB: packs.diskShortfall(pack),
                        refusal: packs.refused[pack],
                        onToggle: { on in
                            // Owner 2026-11-15: nothing of it on disk ⇒ there is nothing to keep or remove, so it just
                            // turns off (the old sheet asked "Keep models" for a pack that had none).
                            if on { packs.enable(pack) } else if packs.frees(pack) == 0 { packs.disable(pack, remove: false) } else { disabling = pack }
                        },
                        onPause: { packs.pause(pack, $0) },
                        onRetry: {
                            SetupLaunch.retry()
                            Task { await packs.reconcileInstalls(retry: true) }  // files already here: finish the install
                            if pack == .video { VideoRuntimeInstall.shared.install() }
                        })
                    .id("pack.\(pack.rawValue)")
                    .modifier(HighlightRow(id: "pack.\(pack.rawValue)"))  // Settings search (step 5)
            }
            if let evil { EvilPackRow(model: evil, packs: packs) }
        }
        .task { await packs.refresh() }
        .sheet(item: $disabling) { pack in
            DisablePackSheet(pack: pack, frees: packs.frees(pack),
                             onKeep: { packs.disable(pack, remove: false); disabling = nil },
                             onRemove: { packs.disable(pack, remove: true); disabling = nil },
                             onCancel: { disabling = nil })
        }
        Section { ToolRows(part: .main, database: database) } header: { GroupHeader("set.tools.builtin") }
        .probeAnchor("settings.toolsPage")  // the anchor only (an id on a Section renames each of its rows, Q-015 r5)
        Section { VoiceSection(part: .main) } header: { GroupHeader("set.voice") }
        if let evil { EvilSettingsPanel(model: evil) }
        AdvancedGroup(model: model, section: .capabilities) {
            AdvancedSection(database: database, packs: packs)
                .probeAnchor("settings.cap.advanced.content")  // r5: an id here was stamped over every override row
            // M2.T21 (R-298): the starter model is removable only here.
            if packs.starterInstalled {
                SettingsItem("starter", description: CopyKey("set.cap.starter.note")) {
                    Button(role: .destructive) { confirmStarter = true } label: {
                        Text(CopyText(CopyKey("set.cap.starter.remove"), ["size": OnboardingModel.size(packs.starterFrees)]))
                    }
                    .disabled(!packs.starterRemovable)
                    .probeID("settings.cap.starter.remove")
                    .confirmationDialog(Text(CopyKey("set.cap.starter")), isPresented: $confirmStarter) {
                        Button(role: .destructive) { packs.removeStarter() } label: {
                            Text(CopyText(CopyKey("set.cap.starter.remove"), ["size": OnboardingModel.size(packs.starterFrees)]))
                        }
                            .accessibilityIdentifier("set.cap.starter.remove")
                    }
                }
            }
            SettingsItem("showModelInfo", description: CopyKey("set.cap.showModelInfo.note")) {
                Toggle(isOn: $showModelInfo) { Text(CopyKey("set.cap.showModelInfo")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.showModelInfo")
            }
            AdvancedHeading("set.tools.builtin")
            ToolRows(part: .advanced, database: database)
            AdvancedHeading("set.voice")
            VoiceSection(part: .advanced)
        }
    }
}

/// Evil Mode as the fifth row of the pack list: Off (with what it downloads) / Downloading n% / Ready, and the one
/// switch for it. On → the 18+ sheet when this terms version has no consent (EvilEnableSheet), then its variants join
/// the download queue; off → Evil chats stay, read-only.
struct EvilPackRow: View {
    @Bindable var model: EvilModeModel
    var packs: PackManagementModel = .shared

    var body: some View {
        PackRow(pack: nil, state: packs.evilState, isOn: model.isOn,
                onToggle: { on in
                    if !on { model.disable() } else if model.isOn { packs.evilEnabled() } else { model.requestEnable() }
                },
                onRetry: { packs.evilEnabled() })
            .id("pack.evil")
            .modifier(HighlightRow(id: "pack.evil"))
            .onChange(of: model.isOn) { _, on in if on { packs.evilEnabled() } }  // queue the Evil variants
            .sheet(isPresented: $model.showEnableSheet) {
                EvilEnableSheet(onContinue: { try? model.enable(adultSelfDeclared: true) },
                                onCancel: { model.showEnableSheet = false })
            }
            .onAppear { model.refresh() }
    }
}

extension EnvironmentValues {
    /// The Evil Mode model the Capabilities page shows instead of the app's (tests).
    @Entry var settingsEvilModel: EvilModeModel? = nil
}

extension ModelPack: Identifiable {
    public var id: String { rawValue }
}
