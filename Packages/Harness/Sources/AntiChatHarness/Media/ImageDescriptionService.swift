// M9.T02 step 5 (NFR-A5, A-M9-T02a): generated pictures get a short description for people who can't see them. The
// vision model writes it after the picture is shown (it never delays display; `.utility`): the chat model when it
// sees, else the helper VLM that stays installed (HelperCaptioner's slot, R-298). Stored by content hash
// (`image_description`), shown and editable in the image viewer's Description field; an edit is never overwritten.
// Incognito pictures (in the incognito temp dir) are described in memory only, never stored.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import CryptoKit
import Foundation

public actor ImageDescriptionService {
    public static let maxTokens = 120
    /// The instruction (model-facing, English per VISION §2.28; the answer comes in `language`).
    static func prompt(language: String) -> String {
        "Write one or two short sentences that describe this picture for someone who can't see it. Mention any "
            + "visible text verbatim. Don't start with \"This image\". Answer in \(language)."
    }

    let store: ImageDescriptionStore
    let describe: @Sendable (_ path: String, _ sha256: String, _ prompt: String) async -> String?
    let language: @Sendable () -> String
    private var memory: [String: ImageDescription] = [:]
    private var running: [String: Task<ImageDescription?, Never>] = [:]

    /// `describe` runs the vision model on one picture (nil = no model can see right now).
    public init(store: ImageDescriptionStore,
                language: @escaping @Sendable () -> String = { Bundle.main.preferredLocalizations.first ?? "en" },
                describe: @escaping @Sendable (_ path: String, _ sha256: String, _ prompt: String) async -> String?) {
        self.store = store
        self.language = language
        self.describe = describe
    }

    /// The engine path: the chat slot's vision variant, else the helper VLM; same preparation as HelperCaptioner.
    public init(store: ImageDescriptionStore, engine: any EngineService, chatSlot: @escaping @Sendable () -> ModelSlot,
                vision: VisionRouting) {
        self.init(store: store) { path, sha, prompt in
            guard let slot = vision.visionSlot(chatSlot()) ?? (vision.captionsAllowed() ? vision.helperSlot() : nil),
                  let png = try? vision.preparer(Self.isIncognito(path)).prepare(URL(fileURLWithPath: path), sha256: sha)
            else { return nil }
            let req = ChatRequest(sessionID: UUID(), modelSlot: slot,
                                  messages: [.message(ChatMessage(role: .user, content: prompt, imagePaths: [png.path]))],
                                  reasoning: .off, sampling: Sampling(temperature: 0, maxTokens: Self.maxTokens))
            var text = ""
            do {
                for try await e in engine.chat(req) {
                    switch e {
                    case .textDelta(let d): text += d
                    case .error(let err):
                        AppLog.log(.harness, .notice, "image description failed: \(err.fullCode)")
                        return nil
                    default: break
                    }
                }
            } catch { return nil }
            return text
        }
    }

    public static func isIncognito(_ path: String) -> Bool { path.contains(IncognitoSession.tempPrefix) }

    public static func sha256(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored (or in-memory) description, without running the model.
    public func current(_ path: String) -> ImageDescription? {
        guard let sha = Self.sha256(of: path) else { return nil }
        return memory[sha] ?? (Self.isIncognito(path) ? nil : try? store.get(sha256: sha))
    }

    /// The description, written by the model first when there is none (one run per picture at a time).
    public func ensure(_ path: String) async -> ImageDescription? {
        guard let sha = Self.sha256(of: path) else { return nil }
        if let d = current(path) { return d }
        if let t = running[sha] { return await t.value }
        let lang = language()
        let name = Locale(identifier: "en").localizedString(forLanguageCode: lang) ?? "English"
        let prompt = Self.prompt(language: name)
        let describe = describe
        let task = Task(priority: .utility) { () -> ImageDescription? in
            guard let raw = await describe(path, sha, prompt) else { return nil }
            let text = Self.clean(raw)
            return text.isEmpty ? nil : ImageDescription(text: text, source: .auto, language: lang)
        }
        running[sha] = task
        let d = await task.value
        running[sha] = nil
        if let d { save(d, sha: sha, path: path) }
        return current(path) ?? d
    }

    /// The user's edit (empty text clears it back to "no description").
    public func setUser(_ path: String, text: String) {
        guard let sha = Self.sha256(of: path) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        save(ImageDescription(text: t, source: .user, language: language()), sha: sha, path: path)
    }

    private func save(_ d: ImageDescription, sha: String, path: String) {
        if Self.isIncognito(path) {
            if d.source == .user || memory[sha]?.source != .user { memory[sha] = d }
        } else {
            _ = try? store.set(sha256: sha, d)
        }
    }

    /// One line, no surrounding quotes or "Description:" lead-in.
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["Description:", "Alt text:"] where t.lowercased().hasPrefix(lead.lowercased()) {
            t = String(t.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        return t.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// The app's instance (set at launch by the composition root; nil in hosts without an engine: the UI then shows the
/// field empty and editable). Same pattern as `MemoryNotice.store`.
public enum ImageDescriptions {
    nonisolated(unsafe) public static var service: ImageDescriptionService?
}
