// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Chat/ChatTitleService.swift (P-shell-02);
// prompt wording after open-webui/open-webui@f7ac7ee:backend/open_webui/config.py
// DEFAULT_TITLE_GENERATION_PROMPT_TEMPLATE.
//
// Auto titles (M1.T19 steps 1–2, R-010 AC1, NFR-U7, IS-2): the chat shows the prompt's first 60 characters at once
// (`temporaryTitle`, `title_state = pending`); once the first reply starts streaming, the title alias model (the
// resident chat model in M1: the starter `chat-0.8b` is the default chat model until M2's catalog; model-matrix §2
// "Title / router") is asked for a 2–6 word title at `.utility`, never blocking the reply. Failures are silent:
// the temporary title stays.
//
// Kept from upstream: the clip sizes (600 user / 800 assistant characters), the 96-token budget (a thinking model
// must not spend it all on reasoning; reasoning is off here too), the 8 s timeout, temperature 0.2, the
// sanitiser (first non-empty line, "Title:" label, markdown and quotes, trailing punctuation, structural
// characters reject, word cap then a word-boundary character clamp). Changed: 2–6 words instead of ≤ 8 (one word
// is rejected: the temporary title is more useful than "Greetings"); the request goes through `EngineService`
// under its own session id (the chat's prefix cache stays untouched); the prompt lives in
// `Resources/prompts/title.txt` (no behaviour clauses).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public struct TitleService: Sendable {
    static let maxUserChars = 600
    static let maxAssistantChars = 800
    public static let maxTokens = 96
    public static let timeout: Duration = .seconds(8)
    static let temperature: Float = 0.2
    public static let minTitleWords = 2
    public static let maxTitleWords = 6
    static let maxTitleChars = 50
    /// Step 1: the temporary title is the prompt's first 60 characters.
    public static let temporaryTitleLength = 60
    /// The title request's system layer id (the ScriptedEngine answers it with the script's `title` line).
    public static let layerID = EngineScript.titleLayerID

    public let engine: any EngineService
    public let slot: ModelSlot
    /// The titler's session (not the chat's).
    public let sessionID: UUID

    public init(engine: any EngineService, slot: ModelSlot, sessionID: UUID = UUID()) {
        self.engine = engine
        self.slot = slot
        self.sessionID = sessionID
    }

    // MARK: Temporary title

    /// The first 60 characters of the prompt on one line (whitespace runs folded), or "" for an empty prompt.
    public static func temporaryTitle(_ prompt: String) -> String {
        let folded = prompt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard folded.count > temporaryTitleLength else { return folded }
        return String(folded.prefix(temporaryTitleLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Generation

    /// The title request (tests check its shape; the ScriptedEngine recognises it by `layerID`).
    public func request(userMessage: String, assistantResponse: String) -> ChatRequest? {
        let user = Self.clip(userMessage.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.maxUserChars)
        let assistant = Self.clip(assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.maxAssistantChars)
        guard !user.isEmpty else { return nil }
        var prompt = "User message:\n\(user)\n\n"
        if !assistant.isEmpty { prompt += "Assistant response:\n\(assistant)\n\n" }
        prompt += "Title:"
        return ChatRequest(
            sessionID: sessionID, modelSlot: slot,
            messages: [.layer(PromptLayer(id: Self.layerID, content: Self.systemPrompt)),
                       .message(ChatMessage(role: .user, content: prompt))],
            reasoning: .off, sampling: Sampling(temperature: Self.temperature, maxTokens: Self.maxTokens))
    }

    /// A sanitised 2–6 word title for the chat's first exchange, or nil on any failure, timeout or quality miss
    /// (the caller keeps the temporary title).
    public func generateTitle(userMessage: String, assistantResponse: String = "") async -> String? {
        guard let request = request(userMessage: userMessage, assistantResponse: assistantResponse) else { return nil }
        let engine = engine
        enum Outcome: Sendable { case finished(String?), timedOut }
        let raw: String? = await withTaskGroup(of: Outcome.self) { group in
            group.addTask(priority: .utility) {
                var text = ""
                do {
                    for try await event in engine.chat(request) {
                        switch event {
                        case .textDelta(let s): text += s
                        case .error: return .finished(nil)
                        case .done(let r): return .finished(r == .cancelled ? nil : text)
                        default: break
                        }
                    }
                } catch {
                    return .finished(nil)
                }
                return .finished(nil)  // ended without a terminal
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            switch await group.next() {
            case .finished(let text)?: return text
            case .timedOut?, nil:
                engine.cancel(request.requestID)
                return nil
            }
        }
        guard let raw, let title = Self.sanitize(raw) else {
            AppLog.log(.harness, .info, "auto title: generation failed silently")
            return nil
        }
        return title
    }

    // MARK: Prompt

    /// `Resources/prompts/title.txt` (falls back to the same text compiled in).
    public static let systemPrompt: String = {
        if let url = Bundle.module.url(forResource: "title", withExtension: "txt", subdirectory: "prompts"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return """
            You name chat conversations. Given the first message of a conversation, reply with ONLY a title of 2 to 6 \
            words that captures its topic. Write the title in the same language as the conversation. No quotes, no \
            trailing punctuation, no emoji, no markdown, no explanations.
            """
    }()

    // MARK: Sanitisation (upstream `sanitize`, 2–6 words)

    /// A raw completion as a sidebar-ready title, or nil when it isn't usable.
    public static func sanitize(_ raw: String) -> String? {
        guard var title = raw.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if let range = title.range(of: #"^\s*title\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            title.removeSubrange(range)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "#*_`"))
        title = title.trimmingCharacters(in: wrappingQuoteCharacters)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = title.last, trailingPunctuation.contains(last) { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if title.contains(where: { "<>{}|".contains($0) }) { return nil }
        let words = title.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count >= minTitleWords else { return nil }
        title = words.prefix(maxTitleWords).joined(separator: " ")
        if title.count > maxTitleChars {
            var clamped = ""
            for word in title.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = clamped.isEmpty ? String(word) : clamped + " " + word
                if candidate.count > maxTitleChars { break }
                clamped = candidate
            }
            guard clamped.split(separator: " ").count >= minTitleWords else { return nil }
            title = clamped
        }
        while let last = title.last, trailingPunctuation.contains(last) { title.removeLast() }
        return title.isEmpty ? nil : title
    }

    private static let wrappingQuoteCharacters = CharacterSet(charactersIn: "\"'“”‘’«»")
    private static let trailingPunctuation: Set<Character> = [".", "!", "?", "…", ",", ";", ":", "。", "！", "？"]

    private static func clip(_ text: String, to limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}
