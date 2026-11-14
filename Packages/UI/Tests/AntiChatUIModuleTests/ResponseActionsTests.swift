// M1.T10 (AT-005 / AT-006, model + pasteboard legs) on the ScriptedEngine and an in-memory database: the
// ConversationModel's regenerate → ‹ 3/3 › → ‹ 2/3 › → ‹ 1/3 › with the original text; Versions list + "Use this
// version"; 👍 writes `feedback(kind=liked)` (the ⌘K Liked filter's source), 👎 → It refused writes `refused`;
// Copy writes the Markdown source as plain text plus RTF and HTML; Edit keeps the attachments the editor kept and
// creates version 2 of the turn; Branch in new chat opens the copy titled "<title> (branch)" in the window.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import GRDB
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ResponseActionsTests {
    static let script = #"{"t":"textDelta","v":"**Answer** v{{v}}.","delayMs":1}"#

    private func make() throws -> (ChatSessions, ChatEnvironment, WindowState) {
        let env = ChatEnvironment(
            database: try AppDatabase.inMemory(),
            engine: InProcessScriptedEngine(script: try EngineScript(text: Self.script)), slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        sessions.openChat = { [weak state] in state?.open(.chat($0)) }
        return (sessions, env, state)
    }

    private func waitIdle(_ m: ConversationModel) async {
        for _ in 0..<500 where m.isGenerating || [.pending, .streaming].contains(m.messages.last?.status) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func sentChat(_ sessions: ChatSessions, _ text: String = "go") async -> ConversationModel {
        let m = sessions.model(for: StorageID.make())
        m.send(text)
        await waitIdle(m)
        return m
    }

    @Test func regenerateVersionsAndSwitcher() async throws {
        let (sessions, _, _) = try make()
        let m = await sentChat(sessions)
        let first = try #require(m.messages.last)
        #expect(first.text == "**Answer** v1.")
        for _ in 0..<2 {
            m.regenerate(try #require(m.messages.last?.id))
            await waitIdle(m)
        }
        var reply = try #require(m.messages.last)
        #expect((reply.version, reply.versionCount) == (3, 3))
        #expect(reply.text == "**Answer** v3.")
        #expect(m.messages.count == 2)

        m.stepVersion(reply.id, by: -1)
        reply = try #require(m.messages.last)
        #expect((reply.version, reply.versionCount, reply.text) == (2, 3, "**Answer** v2."))
        m.stepVersion(reply.id, by: -1)
        reply = try #require(m.messages.last)
        #expect((reply.version, reply.versionCount, reply.text) == (1, 3, "**Answer** v1."))
        #expect(reply.id == first.id)

        // Versions viewer: 3 rows; "Use this version" on 3 restores it.
        let versions = m.versions(of: reply.id)
        #expect(versions.count == 3)
        #expect(versions.map(\.isActive) == [true, false, false])
        m.openVersions(m.messages[0].id)  // ↺ on the user bubble → the reply's versions
        #expect(m.versionsTarget == reply.id)
        #expect(m.hasVersions(m.messages[0].id))
        m.selectVersion(versions[2].id)
        #expect(m.messages.last?.text == "**Answer** v3.")
        #expect(m.messages.last?.version == 3)
    }

    @Test func steeringRegenerateIsNotStored() async throws {
        let (sessions, env, _) = try make()
        let m = await sentChat(sessions)
        m.regenerate(try #require(m.messages.last?.id), options: RegenerateOptions(steering: "shorter please"))
        await waitIdle(m)
        #expect(m.messages.map(\.role) == [.user, .assistant])
        #expect(m.messages.first?.text == "go")
        let parts = try env.database.read { db in try MessagePartRecord.fetchAll(db) }
        #expect(!parts.contains { $0.body.contains("shorter please") })
    }

    @Test func rateLikedDislikedRefused() async throws {
        let (sessions, env, _) = try make()
        let m = await sentChat(sessions)
        let id = try #require(m.messages.last?.id)
        let feedback = FeedbackRepository(env.database)
        m.rate(id, .liked)
        #expect(m.messages.last?.rating == .liked)
        #expect(try feedback.feedback(id).map(\.kind) == [.liked])
        #expect(try feedback.likedMessageIDs() == [id])
        m.rate(id, .liked)  // again clears
        #expect(m.messages.last?.rating == nil)
        #expect(try feedback.likedMessageIDs().isEmpty)
        m.dislike(id)
        m.dislike(id)  // reopening the menu never clears it
        #expect(m.messages.last?.rating == .disliked)
        m.markRefused(id)
        #expect(Set(try feedback.feedback(id).map(\.kind)) == [.disliked, .refused])
        // The rating survives a reload (it is read with the visible path).
        m.load()
        #expect(m.messages.last?.rating == .disliked)
    }

    @Test func copyWritesMarkdownRTFAndHTML() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("antichat-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let markdown = "# Title\n\nSome **bold** and `code`.\n\n- one\n- two\n"
        MessageCopier.copy(markdown: markdown, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == markdown)
        let html = try #require(pasteboard.string(forType: .html))
        #expect(html.contains("<strong>bold</strong>") && html.contains("<h1>Title</h1>"))
        let rtf = try #require(pasteboard.data(forType: .rtf))
        let attributed = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(attributed.string.contains("bold"))
        #expect(!attributed.string.contains("**"))
        // Bold survives as a font trait.
        let range = (attributed.string as NSString).range(of: "bold")
        let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func editKeepsChosenAttachmentsAndCreatesVersionTwo() async throws {
        let (sessions, env, _) = try make()
        let m = await sentChat(sessions, "describe these")
        let user = try #require(m.messages.first)
        let repo = AttachmentRepository(env.database)
        let a = try repo.insert(sha256: String(repeating: "d", count: 64), size: 1, path: "/tmp/001.jpg",
                                origin: .upload, messageID: user.id, displayName: "001.jpg", uti: "public.jpeg")
        _ = try repo.insert(sha256: String(repeating: "e", count: 64), size: 1, path: "/tmp/002.jpg",
                            origin: .upload, messageID: user.id, displayName: "002.jpg", uti: "public.jpeg")
        m.load()
        #expect(m.messages.first?.attachments.map(\.isImage) == [true, true])
        m.beginEdit(user.id)
        #expect(m.editingID == user.id && m.editText == "describe these")
        #expect(m.editAttachments.count == 2)
        m.removeEditAttachment(try #require(m.editAttachments.last?.id))
        m.editText = "describe this one"
        m.submitEdit()
        await waitIdle(m)
        let edited = try #require(m.messages.first)
        #expect((edited.version, edited.versionCount) == (2, 2))
        #expect(edited.text == "describe this one")
        #expect(try repo.attachments(messageID: edited.id).map(\.blobID) == [a.blobID])
        #expect(m.messages.last?.text == "**Answer** v2.")
        // ‹ 1/2: the original prompt with both photos and its original reply.
        m.stepVersion(edited.id, by: -1)
        #expect(m.messages.first?.id == user.id)
        #expect(m.messages.first?.attachments.count == 2)
        #expect(m.messages.last?.text == "**Answer** v1.")
    }

    @Test func branchOpensTheCopyInTheWindow() async throws {
        let (sessions, env, state) = try make()
        let m = await sentChat(sessions)
        try ChatRepository(env.database).rename(m.chatID, title: "Harbour towns")
        let reply = try #require(m.messages.last)
        let before = try MessageTree(env.database).visiblePath(m.chatID).map(\.id)
        let newID = try #require(m.branch(from: reply.id))
        #expect(state.currentChatID == newID)
        #expect(try ChatRepository(env.database).chat(newID)?.title == "Branch · Harbour towns")
        let copy = sessions.model(for: newID)
        #expect(copy.messages.map(\.text) == ["go", "**Answer** v1."])
        #expect(try MessageTree(env.database).visiblePath(m.chatID).map(\.id) == before)
        #expect(try ChatRepository(env.database).chat(m.chatID)?.title == "Harbour towns")
    }
}
