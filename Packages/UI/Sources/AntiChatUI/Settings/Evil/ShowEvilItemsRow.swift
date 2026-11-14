// M5.T13 step 4 (R-022 AC4; settings-map §4 "Show Evil items in Library"): the Settings › Evil Mode switch. Until the
// user touches it, it shows (and the Library follows) the Evil enable state; a choice is stored and sticks.
import AntiChatDesign
import AntiChatStorage
import Defaults
import SwiftUI

struct ShowEvilItemsRow: View {
    let evilEnabled: Bool
    @Default(.showEvilInLibrary) private var setting

    var body: some View {
        Toggle(isOn: Binding(get: { LibraryIndex.showsEvil(setting: setting, evilEnabled: evilEnabled) },
                             set: { setting = $0 })) {
            Text(CopyKey("set.evil.showLibrary"))
        }
        .toggleStyle(.accessibleSwitch)
        .labelsHidden()  // VQ: the switch of a SettingsRow (the row shows the label)
        .probeID("settings.evil.showLibrary")
    }
}
