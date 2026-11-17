// The side panel's Word preview reads through a copy without switched-off run properties (the system reader takes
// `<w:b w:val="false"/>` as bold).
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct DocxPreviewTests {
    @Test func offSwitchesGoAndOnSwitchesStay() {
        let xml = #"<w:rPr><w:b w:val="false"/><w:i w:val="0"/><w:strike w:val="false"/><w:b/><w:i w:val="true"/><w:sz w:val="24"/></w:rPr>"#
        #expect(DocxPreview.withoutOffSwitches(xml) == #"<w:rPr><w:b/><w:i w:val="true"/><w:sz w:val="24"/></w:rPr>"#)
    }
}
