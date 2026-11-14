// M7.T06 step 6 (R-081 AC2; M7.T11 extends it): write verbs win, names only.
import AntiChatTools
import Testing

@Suite struct VerbClassifierTests {
    @Test func splitsSnakeCamelSlugAndDots() {
        #expect(VerbClassifier.words("send_message") == ["send", "message"])
        #expect(VerbClassifier.words("createIssue") == ["create", "issue"])
        #expect(VerbClassifier.words("GMAIL_SEND_EMAIL") == ["gmail", "send", "email"])
        #expect(VerbClassifier.words("files.delete-v2") == ["files", "delete", "v2"])
    }

    @Test func classifies() {
        for w in ["send_message", "createIssue", "GMAIL_SEND_EMAIL", "delete_file", "update_page", "post_comment",
                  "reply_to_thread", "archive_card", "upload_asset", "share_doc", "invite_user", "merge_pr", "close_issue",
                  "assign_ticket", "add_label", "insert_row", "patch_record", "put_object", "move_card", "remove_member"] {
            #expect(VerbClassifier.classify(w) == .write, "\(w)")
        }
        for r in ["search_messages", "list_repos", "getIssue", "fetch_url", "read_file", "find_user"] {
            #expect(VerbClassifier.classify(r) == .read, "\(r)")
        }
        #expect(VerbClassifier.classify("echo") == .unknown)
        #expect(VerbClassifier.classify("search_and_delete") == .write, "a write verb anywhere wins")
        #expect(VerbClassifier.classify("addressBook") == .unknown, "a word, not a substring")
    }
}
