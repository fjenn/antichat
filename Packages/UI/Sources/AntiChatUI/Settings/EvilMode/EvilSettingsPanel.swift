// Settings › Evil Mode (M2.T17 step 7; R-210 AC6, R-211 AC1–AC5; S-24 sheet): one "Enable Evil Mode" switch — on (the enable sheet when this
// terms version has no consent) / off (Evil chats stay, read-only), Hide (no ModeSwitch, no ⇧⌘E, nothing deleted),
// Require Touch ID, Delete all Evil chats (Use memory: EvilSection, M8.T03) (one action, confirmed), and (M2.T19,
// A-M2-T17a) "Remove Evil models — frees {size}": the installed Evil-only models (EvilVariantPlanner.evilOnlyIDs; the
// Photo/Video Evil slots are the Normal ids, Q-009 a, and stay), sized exactly by SpaceAccountant. Shown only when
// something would be freed. The R-227 sizing in the Settings enable path joins in M2.T21.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import SwiftUI

/// "Remove Evil models — frees {size}" (A-M2-T17a): the installed Evil-only model ids and their exact freed bytes.
struct EvilModelRemoval {
    var ids: Set<String>
    var frees: Int64

    static func current(models: ModelsDirectory = DownloadsLaunch.models,
                        catalog: ModelCatalog? = CatalogLaunch.shared?.catalog) -> EvilModelRemoval {
        guard let catalog else { return EvilModelRemoval(ids: [], frees: 0) }
        let installed = Set((try? FileManager.default.contentsOfDirectory(atPath: models.installs.path)) ?? [])
        let ids = EvilVariantPlanner.evilOnlyIDs(catalog: catalog).intersection(installed)
        return EvilModelRemoval(ids: ids, frees: ids.isEmpty ? 0 : SpaceAccountant.frees(ids, models: models))
    }

    /// Evict → delete → GC through the shared helper (M2 review #1/#10), in a detached task (never the main thread).
    /// `done` runs on the main actor once the files are gone.
    func run(models: ModelsDirectory = DownloadsLaunch.models,
             evict: @escaping @Sendable (Set<String>) async -> Void = { _ = await EngineClient.evictConnected($0) },
             done: @escaping @MainActor () -> Void = {}) {
        let ids = self.ids
        Task.detached(priority: .userInitiated) {
            await PackManagementModel.removeModels(ids, models: models, evict: evict)
            await done()
        }
    }
}

struct EvilSettingsPanel: View {
    @Bindable var model: EvilModeModel

    /// F7 (round 66): "Delete all…" acts only when there is an Evil chat to delete.
    static func canDeleteAll(evilChats: Int) -> Bool { evilChats > 0 }
    /// Its label: the danger color when it acts; the disabled text color otherwise (`text.secondary` read as live).
    static func deleteAllColor(evilChats: Int) -> Color { canDeleteAll(evilChats: evilChats) ? .danger : .textDisabled }
    @State private var confirmDelete = false
    @State private var removal = EvilModelRemoval.current()
    @State private var confirmRemove = false

    var body: some View {
        Section {
            Text(CopyKey("set.evil.what"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset
            // M9.T08: the notes sit under their row's label (SettingsRow), as on every other Settings page, not as
            // separate caption rows.
            // M2.T21 (R-227): what turning it on downloads for the enabled packs (Σ unique sha256 − present).
            let cost = PackManagementModel.shared.evilCost
            SettingsRow(CopyText(CopyKey("onb.3.toggle")),
                        description: !model.isOn && cost > 0
                            ? CopyText(CopyKey("set.evil.cost"), ["size": OnboardingModel.size(cost)]) : nil) {
                Toggle(isOn: Binding(get: { model.isOn }, set: { $0 ? model.requestEnable() : model.disable() })) {
                    Text(CopyKey("onb.3.toggle"))
                }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .probeID("settings.evil.enabled")
            }
            .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset
        }
        .onChange(of: model.isOn) { _, on in if on { PackManagementModel.shared.evilEnabled() } }  // queue the Evil variants
        // VQ (S-21 Evil Mode): while Evil Mode is off, its options read as off and disabled, and say why (the switches
        // used to look live: `.disabled` on the Section left the switch style's look unchanged).
        let needsOn = model.isOn ? nil : CopyText(CopyKey("set.evil.needsOn"))
        Section {
            SettingsRow(CopyText(CopyKey("set.evil.hide")), description: CopyText(CopyKey("set.evil.hide.note")), disabledReason: needsOn) {
                Toggle(isOn: Binding(get: { model.isHidden }, set: { model.setHidden($0) })) { Text(CopyKey("set.evil.hide")) }
                    .toggleStyle(.accessibleSwitch)
                    .labelsHidden()
                    .probeID("settings.evil.hide")
            }
            .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset
            SettingsRow(CopyText(CopyKey("set.evil.touchid")), disabledReason: needsOn) {
                Toggle(isOn: Binding(get: { model.requiresTouchID }, set: { model.setTouchID($0) })) {
                    Text(CopyKey("set.evil.touchid"))
                }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .probeID("settings.evil.touchid")
            }
            .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset
            // M9.T08: no "Use memory in Evil chats" here — the live switch is EvilSection's `useMemoryInEvil` row
            // (M8.T03, read by MemoryTool); the old M2 flag row here duplicated it and changed nothing.
            SettingsRow(CopyText(CopyKey("set.evil.showLibrary")), disabledReason: needsOn) {
                ShowEvilItemsRow(evilEnabled: model.isOn)  // M5.T13 (R-022 AC4)
            }
            .padding(.horizontal, Spacing.space1)
            if FeatureFlag.memory.isEnabled(.antichat) { EvilMemoryRow(needsEvilOn: !model.isOn) }  // M8.T03 (R-060 AC4)
        }
        Section {
            // VQ: a row with a label and the count, so the action never sits alone as a faint disabled button.
            SettingsRow(CopyText(CopyKey("set.evil.chats")),
                        description: model.evilChatCount == 0 ? CopyText(CopyKey("set.evil.chats.none"))
                            : CopyText(CopyKey("set.evil.chats.count"), ["count": String(model.evilChatCount)])) {
                let canDelete = Self.canDeleteAll(evilChats: model.evilChatCount)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Text(CopyKey("set.evil.deleteChats.cta")).foregroundStyle(Self.deleteAllColor(evilChats: model.evilChatCount))
                }
                .disabled(!canDelete)
                .opacity(canDelete ? 1 : 0.5)  // F7: a bordered button keeps its bezel when disabled; dim it as well
                .probeID("settings.evil.deleteChats")
                .confirmationDialog(Text(CopyKey("set.evil.deleteChats")), isPresented: $confirmDelete) {
                    Button(role: .destructive) { model.deleteAllEvilChats() } label: { Text(CopyKey("set.evil.deleteChats")) }
                        .accessibilityIdentifier("set.evil.deleteChats")
                }
            }
            .padding(.horizontal, Spacing.space1)
            if removal.frees > 0 {
                let label = CopyText(CopyKey("set.evil.remove"), ["size": OnboardingModel.size(removal.frees)])
                Button(role: .destructive) { confirmRemove = true } label: { Text(label) }
                    .probeID("settings.evil.removeModels")
                    .confirmationDialog(Text(label), isPresented: $confirmRemove) {
                        Button(role: .destructive) { removal.run(done: { removal = EvilModelRemoval.current() }) } label: { Text(label) }
                    }
            }
        }
        .sheet(isPresented: $model.showEnableSheet) {
            EvilEnableSheet(onContinue: { try? model.enable(adultSelfDeclared: true) },
                            onCancel: { model.showEnableSheet = false })
        }
        .onAppear { model.refresh() }
        .probeID("settings.evil.panel")
    }
}
