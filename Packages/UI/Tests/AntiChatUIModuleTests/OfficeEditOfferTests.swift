// M6.T20 (R-276 AC2): without File tools the edit_office_file step carries the offer → OfficeEditOfferCard (install +
// [Re-create the file] + "Formatting may change."); with File tools the edited file is a FileOut card with versions.
//   make test-unit FILTER=OfficeEditOfferTests   (the XCUITest leg OfficeEditOfferTests is pending Q-015)
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct OfficeEditOfferTests {
    @Test func theOfferResultBecomesTheOfferCardAndAnEditAVersionedFileCard() {
        let offer = #"{"office_edit_offer":{"file":"sales.xlsx","format":"xlsx","instruction":"add a total row"}}"#
            + "\nFile tools are not installed, so sales.xlsx was NOT edited."
        let a = ToolActivity(id: "e1", tool: EditOfficeFileTool.name, state: .done, argumentsJSON: #"{"file":"sales.xlsx"}"#, result: offer)
        #expect(OfficeEditActivity.isEdit(a))
        #expect(OfficeEditActivity.offer(a) == OfficeEditOffer(file: "sales.xlsx", format: "xlsx", instruction: "add a total row"))
        #expect(CopyKey("edit.formattingMayChange").string() == "Formatting may change.")
        #expect(CopyKey("edit.recreate").string() == "Re-create the file")
        let edited = #"{"artifact_id":"a1","file":"sales.xlsx","format":"xlsx","path":"/tmp/x/b.xlsx","size":10,"version":2,"versions":[{"n":1,"path":"/tmp/x/a.xlsx","size":9},{"n":2,"path":"/tmp/x/b.xlsx","size":10}]}"#
        let b = ToolActivity(id: "e2", tool: EditOfficeFileTool.name, state: .done, result: edited)
        #expect(OfficeEditActivity.offer(b) == nil)
        #expect(FileOutActivity.isFileOut(b))
        #expect(FileOutActivity.versions(b).count == 2)
    }
}
