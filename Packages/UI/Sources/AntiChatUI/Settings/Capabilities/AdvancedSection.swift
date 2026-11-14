// M2.T07 (R-222 AC2–AC4; S-21 Capabilities › Advanced, collapsed): per pack × mode a ModelOverrideRow, "Reset to
// recommended" per pack, keep-loaded (5 / 15 / 30 min / Never, default 15; NFR-M2) and "Allow loads above the memory
// budget" (off; NFR-R5). The scheduler reads the last two through `SetPolicy` (T12). Overrides are `model_override`
// rows (ModelOverrideStore) that the selector re-resolves against every catalog; a revoked one falls back with
// `model.revoked`. M5.T09: Advanced → Video (VideoAdvancedView) below the memory rows.
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import Defaults
import Observation
import SwiftUI

@MainActor @Observable
final class AdvancedModel {
    var profile: HardwareProfile?
    var catalog: ModelCatalog?
    var selection: Selection?
    var overrides: [ModelOverride] = []
    var fellBack: [ModelOverride] = []
    private let store: ModelOverrideStore?
    private let catalogStore: CatalogStore?
    /// The chats' selection memo: an override change must reach the next turn without a relaunch (M2 review #6).
    private let chatModels: ChatModels

    init(database: AppDatabase?, catalogStore: CatalogStore? = CatalogLaunch.shared, chatModels: ChatModels = .shared) {
        store = database.map(ModelOverrideStore.init)
        self.catalogStore = catalogStore
        self.chatModels = chatModels
    }

    func load(database: AppDatabase?) async {
        if profile == nil { profile = await HardwareProbe.shared.current(database: database, dataRoot: AppBootstrap.dataRoot) }
        recompute()
    }

    func recompute() {
        catalog = catalogStore?.catalog
        overrides = store?.all() ?? []
        guard let catalog, let profile else { return }
        let r = ModelOverrideStore.resolve(overrides, catalog: catalog, isLoadable: catalogStore.map { s in { s.isLoadable($0) } })
        fellBack = r.fellBack
        selection = ModelSelector(catalog: catalog).select(profile: profile, modes: [.normal, .evil], overrides: r.overrides,
                                                           allowOverBudget: Defaults[.allowOverBudget])
    }

    func options(_ pack: ModelPack, _ mode: ModelMode) -> [ModelOverrideStore.Option] {
        guard let catalog, let profile else { return [] }
        let recommended = ModelSelector(catalog: catalog).select(profile: profile, modes: [.normal, .evil])
        return ModelOverrideStore.options(pack: pack, mode: mode, selection: recommended, catalog: catalog, profile: profile,
                                          allowOverBudget: Defaults[.allowOverBudget])
    }

    func pick(_ pack: ModelPack, _ mode: ModelMode, _ id: String?) {
        try? store?.set(pack, mode, modelID: id)
        chatModels.invalidate()
        recompute()
    }

    func reset(_ pack: ModelPack) {
        try? store?.reset(pack)
        chatModels.invalidate()
        recompute()
    }
}

struct AdvancedSection: View {
    let database: AppDatabase?
    @State private var model: AdvancedModel
    @Default(.keepLoadedMinutes) private var keepLoaded
    @Default(.allowOverBudget) private var allowOver
    @Default(.yieldGPU) private var yieldGPU

    init(database: AppDatabase?) {
        self.database = database
        _model = State(initialValue: AdvancedModel(database: database))
    }

    var body: some View {
        Group {
            ForEach(ModelPack.allCases, id: \.self) { pack in
                // VQ (S-21 Capabilities): inside the disclosure the Form draws no separators; one per pack group.
                if pack != ModelPack.allCases.first { Divider() }
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    ForEach(ModelMode.allCases, id: \.self) { mode in
                        ModelOverrideRow(pack: pack, mode: mode, current: slot(pack, mode), options: model.options(pack, mode),
                                         overridden: model.overrides.first { $0.pack == pack && $0.mode == mode }?.modelID,
                                         onPick: { model.pick(pack, mode, $0) }, catalog: model.catalog)
                    }
                    if model.overrides.contains(where: { $0.pack == pack }) {
                        Button { model.reset(pack) } label: { Text(CopyKey("set.cap.reset")) }
                            .accessibilityIdentifier("override.reset.\(pack.rawValue)")
                    }
                }
                .padding(.horizontal, Spacing.space1)  // the SettingsItem inset of the rows below (M2.T26 VQ alignment)
                .id(pack == .chat ? "modelOverrides" : "modelOverrides.\(pack.rawValue)")
            }
            ForEach(model.fellBack, id: \.modelID) { o in
                Text(CopyText(CopyKey("model.revoked"), ["model": ModelNames.name(o.modelID, catalog: model.catalog),
                                                        "replacement": slot(o.pack, o.mode)?.modelID.map { ModelNames.name($0, catalog: model.catalog) }
                                                            ?? CopyKey("set.cap.recommended").string()]))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("override.revoked")
            }
            Divider()
            SettingsItem("keepLoadedMinutes") {
                Picker(selection: $keepLoaded) {
                    Text(CopyKey("set.cap.keepLoaded.m5")).tag(5)
                    Text(CopyKey("set.cap.keepLoaded.m15")).tag(15)
                    Text(CopyKey("set.cap.keepLoaded.m30")).tag(30)
                    Text(CopyKey("set.cap.keepLoaded.never")).tag(0)
                } label: { Text(CopyKey("set.cap.keepLoaded.label")) }  // own label (M9.T03: SettingsRow no longer labels the control)
                .labelsHidden()
                .fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.keepLoadedMinutes")
            }
            Divider()
            SettingsItem("allowOverBudget") {
                Toggle(isOn: $allowOver) { Text(CopyKey("set.cap.allowOver")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.allowOverBudget")
            }
            // M5.T09 (R-044 AC2): Advanced → Video — steps, resolution, exact length (never on the plan card).
            Divider()
            VideoAdvancedView(tier: model.profile?.tier.rawValue, speedClass: model.profile?.speedClass.rawValue)
            // M5.T11 (NFR-B5): pause the running video job while another app holds the GPU (default on).
            Divider()
            SettingsItem("yieldGPU") {
                Toggle(isOn: $yieldGPU) { Text(CopyKey("set.capabilities.yieldGPU")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.yieldGPU")
            }
        }
        .task { await model.load(database: database) }
        .onChange(of: allowOver) { model.recompute() }
        .onReceive(NotificationCenter.default.publisher(for: CatalogStore.didChange)) { _ in model.recompute() }
    }

    private func slot(_ pack: ModelPack, _ mode: ModelMode) -> SelectionSlot? {
        pack == .chat ? model.selection?.slot(.chat, mode, role: "chat") : model.selection?.slot(pack, mode)
    }
}
