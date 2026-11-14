// Settings → Capabilities (M1.T22 step 1; settings-map §3; R-100 AC4): Chat (on, locked), the packs' row
// (M2.T21: PackRow per pack, DisablePackSheet, the starter under Advanced) and the **Advanced** disclosure, collapsed by default (`set.cap.advanced`):
// model per pack × mode, Reset to recommended, keep-loaded and allow-over-budget (M2.T07, AdvancedSection).
import AntiChatDesign
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

    var body: some View {
        CatalogStatusBanner(store: CatalogLaunch.shared)
        ModelUpdateRows(status: ModelUpdatesLaunch.status)
        Section {
            // M2.T21 (R-202 AC1): Chat (locked on) + Voice, Photo, Video.
            ForEach(ModelPack.allCases, id: \.self) { pack in
                PackRow(pack: pack, state: packs.state(pack), modes: packs.modesLine(pack),
                        isOn: pack == .chat || packs.isOn(pack), diskShortGB: packs.diskShortfall(pack),
                        refusal: packs.refused[pack],
                        onToggle: { on in if on { packs.enable(pack) } else { disabling = pack } },
                        onPause: { packs.pause(pack, $0) },
                        onRetry: { SetupLaunch.retry() })
                    .id("pack.\(pack.rawValue)")
                    .modifier(HighlightRow(id: "pack.\(pack.rawValue)"))  // Settings search (step 5)
            }
        } footer: {
            // VQ (S-21 Capabilities): how much room the downloads have (the disk rule's own figure).
            Text(CopyText(CopyKey("storage.free"), ["size": OnboardingModel.size(packs.freeBytes())]))
                .typeStyle(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.space1)
                .probeID("settings.cap.freeDisk")
        }
        .task { await packs.refresh() }
        .sheet(item: $disabling) { pack in
            DisablePackSheet(pack: pack, frees: packs.frees(pack),
                             onKeep: { packs.disable(pack, remove: false); disabling = nil },
                             onRemove: { packs.disable(pack, remove: true); disabling = nil },
                             onCancel: { disabling = nil })
        }
        Section {
            DisclosureGroup(isExpanded: $model.advancedExpanded) {
                AdvancedSection(database: database)
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
                SettingsItem("showModelInfo") {
                    Toggle(isOn: $showModelInfo) { Text(CopyKey("set.cap.showModelInfo")) }
                        .toggleStyle(.accessibleSwitch)
                        .probeID("settings.control.showModelInfo")
                }
            } label: {
                // Q-015 r5: in a grouped Form the chevron sits at the row's trailing edge and the label did nothing on
                // click; the audit also found the row with no press action (VoiceOver could not open it). The label
                // toggles the group, as a System Settings row does.
                Button { model.advancedExpanded.toggle() } label: {
                    Text(CopyKey("set.cap.advanced")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // VQ: the reveal highlight sits on this header row only; on the DisclosureGroup it washed the whole
                // open group in the accent tint for 2.5 s (seen as a lavender Advanced block).
                .modifier(HighlightRow(id: "capabilities.advanced"))
                // On the label, not the DisclosureGroup: there the id was stamped over every row inside the group
                // (`override.chat.normal` and the rest all read "settings.row.capabilities.advanced", AX dump r5).
                .probeID("settings.row.capabilities.advanced")
            }
            .disclosureGroupStyle(.accessible)  // M9.T03: the triangle's press action
            .id("capabilities.advanced")
        }
    }
}

extension ModelPack: Identifiable {
    public var id: String { rawValue }
}
