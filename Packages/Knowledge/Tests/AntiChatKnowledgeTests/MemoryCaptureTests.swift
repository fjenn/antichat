// Per-turn memory capture (owner 2026-11-17): the gate's table (which user messages are worth one extraction call) and
// MemoryCapture's handling of what the model answers: certain → saved with its event, unsure → pending, known /
// handled before / sensitive off / unparseable → nothing, not On or not gated → no call, cancelled → no write.
//   make test-unit FILTER=MemoryCaptureGateTests,MemoryCaptureTests
import AntiChatStorage
import Foundation
import GRDB
import Synchronization
import Testing
@testable import AntiChatKnowledge

@Suite struct MemoryCaptureGateTests {
    static let positive: [String] = [
        // en
        "From now on I always want measurements in metric units. Which is longer, a mile or a kilometre?",
        "remember that my sister is called Ana",
        "I'm a nurse, how do I ask for a night-shift allowance?",
        "My name is Armando.",
        "Call me Sam.",
        "I work as a product designer in Lisbon.",
        "I live in Rotterdam and commute by bike.",
        "I prefer short answers without bullet points.",
        "Please always answer in British English.",
        "I don't like emoji in replies.",
        "My wife is vegetarian, so suggest a dinner for two.",
        "Don't ever use the word delve.",
        "I\u{2019}m allergic to peanuts.",
        "Going forward, keep code samples in Swift.",
        "Can you remember that I take my coffee black?",
        // nl
        "Vanaf nu wil ik alle antwoorden in het Nederlands.",
        "Ik ben leraar op een basisschool.",
        "Ik woon in Utrecht.",
        "Onthoud dat mijn dochter Sanne heet.",
        "Mijn vrouw is jarig op 3 mei.",
        "Ik hou van korte antwoorden.",
        "Noem me Jan.",
        "Ik werk als verpleegkundige, wat is een goed rooster?",
        // de
        "Ab jetzt bitte immer auf Deutsch antworten.",
        "Ich bin Softwareentwicklerin.",
        "Ich heiße Jonas.",
        "Ich wohne in München.",
        "Merk dir, dass ich Vegetarier bin.",
        "Meine Tochter heißt Lena.",
        "Ich bevorzuge kurze Antworten.",
        "Ich arbeite als Lehrer, wie plane ich die Woche?",
        // fr
        "Désormais, réponds-moi toujours en français.",
        "Je suis infirmière à Lyon.",
        "Je m'appelle Claire.",
        "J\u{2019}habite à Bordeaux.",
        "Souviens-toi que ma sœur s'appelle Ana.",
        "Je préfère les réponses courtes.",
        "N'oublie pas que je suis végétarien.",
        "Mon mari travaille de nuit, propose un planning.",
        // es
        "A partir de ahora, responde siempre en español.",
        "Soy médico en Sevilla.",
        "Me llamo Lucía.",
        "Vivo en Valencia.",
        "Recuerda que mi hermana se llama Ana.",
        "Prefiero respuestas cortas.",
        "No me gusta el cilantro.",
        "Mi esposa es celíaca, ¿qué podemos cenar?",
        // pt
        "A partir de agora, responda sempre em português.",
        "Sou engenheira em Lisboa.",
        "Me chamo Rafael.",
        "Moro em São Paulo.",
        "Lembre-se de que minha irmã se chama Ana.",
        "Prefiro respostas curtas.",
        "Não gosto de coentro.",
        "O meu marido é vegetariano, o que posso cozinhar?",
    ]

    static let pastedLyrics = (["Summarise the text below.", "Keep it to two lines."]
        + Array(repeating: "I am the walrus and I live in a yellow submarine.", count: 20) + ["Thanks.", "Is that clear?"])
        .joined(separator: "\n")

    static let negative: [String] = [
        // en
        "my hard drive is full",
        "what's my name?",
        "Which is longer, a mile or a kilometre?",
        "Summarise this article in three bullet points.",
        "I'm trying to fix a bug in this function.",
        "I'm getting an error when I run npm install.",
        "Translate \"I live in Berlin and I love it\" into French.",
        "> I prefer tea\nWho wrote this line?",
        "Write a poem about the sea.",
        "Do I like jazz?",
        "What do I prefer, tea or coffee?",
        "Add soy sauce to the recipe.",
        "How do I get to the station?",
        "Fix the grammar: \u{201C}my name is john and i am a doctor\u{201D}",
        "```\nprint('I am a robot')\n```\nWhy does this print twice?",
        pastedLyrics,
        "Proofread this: " + String(repeating: "I am a teacher and I live in Leeds with my wife. ", count: 8),
        "Can you explain how memory works in Swift?",
        "Is it true that the future is uncertain?",
        "I'm not sure this is right.",
        "Thanks, that helps.",
        "Do you remember my name?",
        "",
        // nl
        "Wat is mijn naam?",
        "Mijn harde schijf is vol.",
        "Vat dit artikel samen.",
        "Ik ben aan het proberen dit script te repareren.",
        "Hoe laat is het in Tokio?",
        "Schrijf een gedicht over de zee.",
        "Waar woon ik?",
        // de
        "Wie heiße ich?",
        "Meine Festplatte ist voll.",
        "Fasse diesen Artikel zusammen.",
        "Ich bin mir nicht sicher, ob das stimmt.",
        "Wie spät ist es in Tokio?",
        "Schreib ein Gedicht über das Meer.",
        "Was mag ich?",
        "Übersetze „Ich wohne in Berlin“ ins Englische.",
        // fr
        "Comment je m'appelle ?",
        "Mon disque dur est plein.",
        "Résume cet article.",
        "Je suis en train de corriger ce script.",
        "Quelle heure est-il à Tokyo ?",
        "Écris un poème sur la mer.",
        "Est-ce que j'aime le jazz ?",
        "Traduis «\u{A0}je suis médecin\u{A0}» en anglais.",
        // es
        "¿Cómo me llamo?",
        "Mi disco duro está lleno.",
        "Resume este artículo.",
        "¿Qué hora es en Tokio?",
        "Escribe un poema sobre el mar.",
        "¿Dónde vivo?",
        "Explica cómo funciona la memoria en Swift.",
        // pt
        "Qual é o meu nome?",
        "Meu disco rígido está cheio.",
        "Resuma este artigo.",
        "Que horas são em Tóquio?",
        "Escreva um poema sobre o mar.",
        "Onde eu moro?",
        "Explique como funciona a memória em Swift.",
    ]

    @Test func theTableHasEnoughRows() {
        #expect(Self.positive.count >= 40 && Self.negative.count >= 40)
        #expect(Set(MemoryCaptureGate.table.keys) == ["en", "nl", "de", "fr", "es", "pt"])
        print("memory capture gate: \(MemoryCaptureGate.cueCount) cues in \(MemoryCaptureGate.table.count) languages")
    }

    @Test(arguments: positive)
    func firesOnALastingStatement(_ message: String) {
        #expect(MemoryCaptureGate.fires(message), "\(message)")
    }

    @Test(arguments: negative)
    func staysQuietOtherwise(_ message: String) {
        let hit = MemoryCaptureGate.evaluate(message)
        #expect(hit == nil, "\(message) → \(hit?.cue ?? "")")
    }

    @Test func theExcerptIsTheUsersOwnShortLinesCapped() throws {
        let long = String(repeating: "word ", count: 80)  // 400 characters: a pasted line
        let hit = try #require(MemoryCaptureGate.evaluate("I prefer metric units.\n> quoted\n\(long)\nPlease convert this."))
        #expect(hit.cue == "i prefer")
        #expect(hit.excerpt == "I prefer metric units.\nPlease convert this.")
        let many = try #require(MemoryCaptureGate.evaluate(Array(repeating: "I am a nurse and I like tea.", count: 60).joined(separator: "\n")))
        #expect(many.excerpt.count <= MemoryCaptureGate.maxExcerptChars)
    }
}

/// Answers the extraction prompt with `facts` and the decider's comparison with `decision`; counts the calls. `hold`:
/// the answer comes only once the calling task is cancelled.
final class CaptureModel: MemoryDecisionModel, Sendable {
    let facts: String?
    let decision: String?
    let hold: Bool
    let calls = Mutex(0)
    let prompts = Mutex<[String]>([])

    init(facts: String?, decision: String? = #"{"event":"ADD"}"#, hold: Bool = false) {
        self.facts = facts
        self.decision = decision
        self.hold = hold
    }

    func complete(system: String, user: String) async -> String? {
        calls.withLock { $0 += 1 }
        prompts.withLock { $0.append(user) }
        if hold { try? await Task.sleep(for: .seconds(60)) }
        guard system == MemoryUpdateDecider.systemPrompt else { return facts }
        return decision.map { $0.replacingOccurrences(of: "$FIRST", with: ScriptedDecisionModel.firstID(user) ?? "") }
    }
}

@Suite struct MemoryCaptureTests {
    static let metric = "From now on I always want measurements in metric units. Which is longer, a mile or a kilometre?"
    static let certain = #"[{"topic":"Units","text":"Wants measurements in metric units","confidence":"certain","sensitive_category":"none"}]"#
    static let unsure = #"[{"topic":"Units","text":"May prefer metric units","confidence":"unsure","sensitive_category":"none"}]"#

    func capture(_ model: CaptureModel) throws -> (MemoryCapture, MemoryStore, AppDatabase) {
        let (db, store) = try memoryDB()
        return (MemoryCapture(store: store, model: model, embedder: nil), store, db)
    }

    func suggestions(_ db: AppDatabase) throws -> [MemorySuggestion] {
        try db.read { try MemorySuggestion.order(Column("created_at")).fetchAll($0) }
    }

    @Test func aCertainFactIsSavedWithItsEvent() async throws {
        let model = CaptureModel(facts: Self.certain)
        let (c, store, db) = try capture(model)
        let out = await c.run(userText: Self.metric, chatID: "c1", userMessageID: nil, policy: MemoryPolicy())
        let active = try store.active()
        #expect(active.map(\.item.text) == ["Wants measurements in metric units"])
        #expect(active[0].item.origin == .review && active[0].item.sourceChatID == "c1" && active[0].topic.name == "Units")
        let events = try store.events(itemID: active[0].item.id).map(\.id)
        #expect(out.called && out.eventIDs == events && out.eventIDs.count == 1)
        #expect(out.saved.map(\.id) == [active[0].item.id] && out.pending.isEmpty)
        #expect(try suggestions(db).map(\.state) == [.saved])
        #expect(model.calls.withLock { $0 } == 1, "nothing stored yet: no comparison call")
        // The model read the user's words, not more.
        #expect(model.prompts.withLock { $0[0] } == "User message:\n\(Self.metric)\n\nJSON:")
        // Undo removes it (the reply's line), and the same message again does not bring it back.
        try store.undo(eventID: out.eventIDs[0])
        let again = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(again.called && again.eventIDs.isEmpty && again.pending.isEmpty)
        #expect(try store.active().isEmpty)
    }

    @Test func anUnsureFactBecomesAPendingSuggestion() async throws {
        let (c, store, db) = try capture(CaptureModel(facts: Self.unsure))
        let out = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(out.eventIDs.isEmpty && out.pending.map(\.text) == ["May prefer metric units"])
        #expect(try store.active().isEmpty)
        #expect(try suggestions(db).map(\.state) == [.pending])
        #expect(try MemoryReviewService(store: store, model: nil, embedder: nil).pending().map(\.id) == out.pending.map(\.id))
        // Not suggested twice.
        let again = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(again.pending.isEmpty)
        #expect(try suggestions(db).count == 1)
    }

    @Test func aCertainFactThatTouchesAnExistingMemoryIsLeftToTheUser() async throws {
        let model = CaptureModel(facts: Self.certain, decision: #"{"event":"UPDATE","id":"$FIRST","text":"Wants metric units"}"#)
        let (c, store, db) = try capture(model)
        try store.insert(topic: "Units", key: "units", text: "Wants measurements in imperial units", origin: .user)
        let out = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(out.eventIDs.isEmpty && out.pending.count == 1)
        #expect(try store.active().map(\.item.text) == ["Wants measurements in imperial units"])
        #expect(try suggestions(db).map(\.state) == [.pending])
        // A comparison that failed is unsure too.
        let failing = CaptureModel(facts: Self.certain, decision: "no idea")
        let (c2, store2, _) = try capture(failing)
        try store2.insert(topic: "Units", key: "units", text: "Wants measurements in imperial units", origin: .user)
        let out2 = await c2.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(out2.eventIDs.isEmpty && out2.pending.count == 1)
    }

    @Test func aFactThatIsAlreadyStoredWritesNothing() async throws {
        let (c, store, db) = try capture(CaptureModel(facts: Self.certain))
        // What the turn's own `memory` call (or the user) stored: same words, other case and punctuation.
        try store.insert(topic: "Units", key: "units", text: "wants measurements in Metric units.", origin: .tool)
        let out = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(out.called && out.eventIDs.isEmpty && out.pending.isEmpty)
        #expect(try store.active().count == 1)
        #expect(try suggestions(db).isEmpty)
        // An existing memory that covers it (the comparison says NONE): nothing either.
        let covered = CaptureModel(facts: Self.certain, decision: #"{"event":"NONE","id":"$FIRST"}"#)
        let (c2, store2, db2) = try capture(covered)
        try store2.insert(topic: "Units", key: "units", text: "Uses metric units for measurements", origin: .user)
        let out2 = await c2.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
        #expect(out2.eventIDs.isEmpty && out2.pending.isEmpty)
        #expect(try store2.active().count == 1)
        #expect(try suggestions(db2).isEmpty)
    }

    @Test func outputThatDoesNotParseWritesNothing() async throws {
        for raw in ["Sure, I noted that you prefer metric units.", #"[{"topic":"Units","text":"Wants metric"#, "[]", nil] as [String?] {
            let (c, store, db) = try capture(CaptureModel(facts: raw))
            let out = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy())
            #expect(out.called && out.eventIDs.isEmpty && out.pending.isEmpty)
            #expect(try store.active().isEmpty)
            #expect(try suggestions(db).isEmpty)
        }
    }

    @Test func sensitiveFactsNeedTheSettingAndAtMostTwoFactsAreRead() async throws {
        let facts = #"[{"topic":"Health","text":"Has asthma since childhood","confidence":"certain","sensitive_category":"health"},{"topic":"Work","text":"Works as a nurse","confidence":"certain"},{"topic":"Home","text":"Lives in Lisbon","confidence":"certain"}]"#
        let (c, store, _) = try capture(CaptureModel(facts: facts))
        let out = await c.run(userText: "I'm a nurse with asthma and I live in Lisbon.", chatID: "c1", policy: MemoryPolicy())
        #expect(out.saved.map(\.text) == ["Works as a nurse"], "sensitive off; the third fact is not read")
        #expect(try store.active().contains { $0.topic.sensitiveCategory != nil } == false)
        let (c2, store2, _) = try capture(CaptureModel(facts: facts))
        let on = await c2.run(userText: "I'm a nurse with asthma and I live in Lisbon.", chatID: "c1",
                              policy: MemoryPolicy(includeSensitive: true))
        #expect(on.saved.map(\.text) == ["Has asthma since childhood", "Works as a nurse"])
        #expect(try store2.active().first { $0.item.text == "Has asthma since childhood" }?.topic.sensitiveCategory == .health)
    }

    @Test(arguments: [MemoryPolicy.Mode.paused, .off])
    func noCallUnlessMemoryIsOn(mode: MemoryPolicy.Mode) async throws {
        let model = CaptureModel(facts: Self.certain)
        let (c, store, _) = try capture(model)
        let out = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy(mode: mode))
        #expect(!out.called && model.calls.withLock { $0 } == 0)
        #expect(try store.active().isEmpty)
    }

    @Test func noCallForAMessageTheGateLeavesOutOrWithoutAModel() async throws {
        let model = CaptureModel(facts: Self.certain)
        let (c, store, _) = try capture(model)
        let out = await c.run(userText: "Which is longer, a mile or a kilometre?", chatID: "c1", policy: MemoryPolicy())
        #expect(!out.called && model.calls.withLock { $0 } == 0)
        let none = MemoryCapture(store: store, model: nil, embedder: nil)
        #expect(await none.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy()).called == false)
        #expect(try store.active().isEmpty)
    }

    @Test func aCancelledCaptureWritesNothing() async throws {
        let model = CaptureModel(facts: Self.certain, hold: true)
        let (c, store, db) = try capture(model)
        let task = Task { await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy()) }
        while model.calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        let out = await task.value
        #expect(out.called && out.eventIDs.isEmpty && out.pending.isEmpty)
        #expect(try store.active().isEmpty)
        #expect(try suggestions(db).isEmpty)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM memory_event") } == 0)
    }

    @Test func projectOnlyMemoryKeepsTheFactInItsProject() async throws {
        let (c, store, db) = try capture(CaptureModel(facts: Self.certain))
        let project = try ProjectStore(database: db).create(name: "Lab")
        let out = await c.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy(), projectID: project.id)
        #expect(out.saved.map(\.scope) == [.project] && out.saved.first?.projectID == project.id)
        #expect(try store.active().isEmpty, "nothing global")
        let (c2, _, db2) = try capture(CaptureModel(facts: Self.unsure))
        let p2 = try ProjectStore(database: db2).create(name: "Lab")
        let out2 = await c2.run(userText: Self.metric, chatID: "c1", policy: MemoryPolicy(), projectID: p2.id)
        #expect(out2.pending.isEmpty, "the suggestion list is global")
        #expect(try suggestions(db2).isEmpty)
    }

    @Test func theExtractionPromptStaysTiny() {
        // Every tier pays it once per gated message (≈ 4 characters per token).
        #expect(MemoryCapture.systemPrompt.count <= 800)
        #expect(MemoryCapture.budget.maxTokens <= 160 && MemoryCapture.budget.timeout <= .seconds(10))
    }
}
