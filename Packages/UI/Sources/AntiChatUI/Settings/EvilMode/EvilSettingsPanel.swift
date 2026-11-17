// Settings › Capabilities › Evil Mode (M2.T17 step 7; R-210 AC6, R-211 AC1–AC5; S-24 sheet): Evil Mode's own options.
// Its on/off switch is the Evil row of the pack list at the top of the page (EvilPackRow, owner 2026-11-16); this
// group shows only once there is something to set or remove: with Evil on — Hide (no ModeSwitch, no ⇧⌘E, nothing
// deleted), Require Touch ID, Show Evil items in Library, Use memory (M8.T03); while there are Evil chats — their
// count and Delete all Evil chats (one action, confirmed); and (M2.T19,
// A-M2-T17a) "Remove Evil models — frees {size}": the installed Evil-only models (EvilVariantPlanner.evilOnlyIDs; the
// Photo/Video Evil slots are the Normal ids, Q-009 a, and stay), sized exactly by SpaceAccountant. Shown only when
// something would be freed. The R-227 sizing in the Settings enable path joins in M2.T21.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import Defaults
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
        // Nothing to set or remove (Evil off, no Evil chats, no Evil-only models): no group at all.
        if model.isOn || model.evilChatCount > 0 || removal.frees > 0 { group }
    }

    private var group: some View {
        Section {
            // Its options appear once Evil Mode is on (the switch itself is the Evil row of the list above).
            if model.isOn { options }
            if model.isOn || model.evilChatCount > 0 { chatsRow }
            if removal.frees > 0 {
                let label = CopyText(CopyKey("set.evil.remove"), ["size": OnboardingModel.size(removal.frees)])
                Button(role: .destructive) { confirmRemove = true } label: { Text(label) }
                    .padding(.horizontal, Spacing.space1)
                    .probeID("settings.evil.removeModels")
                    .confirmationDialog(Text(label), isPresented: $confirmRemove) {
                        Button(role: .destructive) { removal.run(done: { removal = EvilModelRemoval.current() }) } label: { Text(label) }
                    }
            }
        } header: {
            GroupHeader("set.evil")
        }
        .onAppear { model.refresh() }
        .probeAnchor("settings.evil.panel")  // the anchor only: an id on a Section is stamped over each of its rows
    }

    @ViewBuilder private var options: some View {
        SettingsRow(CopyText(CopyKey("set.evil.hide")), description: CopyText(CopyKey("set.evil.hide.note"))) {
            Toggle(isOn: Binding(get: { model.isHidden }, set: { model.setHidden($0) })) { Text(CopyKey("set.evil.hide")) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .probeID("settings.evil.hide")
        }
        .padding(.horizontal, Spacing.space1)
        SettingsRow(CopyText(CopyKey("set.evil.touchid"))) {
            Toggle(isOn: Binding(get: { model.requiresTouchID }, set: { model.setTouchID($0) })) {
                Text(CopyKey("set.evil.touchid"))
            }
            .toggleStyle(.accessibleSwitch)
            .labelsHidden()
            .probeID("settings.evil.touchid")
        }
        .padding(.horizontal, Spacing.space1)
        SettingsItem("showEvilInLibrary") { ShowEvilItemsRow(evilEnabled: model.isOn) }  // M5.T13 (R-022 AC4)
        if FeatureFlag.memory.isEnabled(.antichat) { EvilMemoryRow() }  // M8.T03 (R-060 AC4)
    }

    /// The Evil chats with their count and the one delete action (shown while there is anything to say).
    private var chatsRow: some View {
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
    }
}

/// "Use memory in Evil chats" (settings-map §4, default On; read by MemoryTool).
struct EvilMemoryRow: View {
    @Default(.useMemoryInEvil) private var on
    var body: some View {
        SettingsItem("useMemoryInEvil") {
            Toggle(isOn: $on) { Text(CopyKey("set.evil.memory")) }
                .toggleStyle(.accessibleSwitch).labelsHidden()
                .probeID("settings.control.useMemoryInEvil")
        }
    }
}
