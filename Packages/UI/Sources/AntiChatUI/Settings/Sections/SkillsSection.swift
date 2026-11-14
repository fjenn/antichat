// Settings → Skills (M1.T22 step 1; settings-map §8). M7.T12 (R-082, R-261): the installed skills and Add skill
// (SkillsPage). Create a skill by chat is M7.T13 (R-264).
import SwiftUI

struct SkillsSection: View {
    var body: some View {
        Section { SettingsItem("skills") { EmptyView() }; SkillsPage() }
    }
}
