// Per-turn memory capture, step 1 (owner 2026-11-17): a cheap deterministic gate on the user's message that decides
// whether one short extraction call is worth spending (MemoryCapture). It never decides what is saved; it only has to
// let through messages that plausibly state something lasting about the user or how they want answers, so it favours
// recall and leaves the judgement to the model. A message that does not fire costs nothing.
//
// What is looked at: the user's own short statements only. Quoted lines (`>`), fenced code, text inside double quotes
// and long lines (pasted text) are dropped; a long message keeps its first and last short lines (the user's framing
// around a paste); the rest is capped. The text is split into clauses; a cue of kind `statement` ("I am", "I prefer",
// "my sister") does not count in a question clause ("what's my name?"), a cue of kind `anywhere` ("remember that",
// "from now on") always counts.
//
// The table has one entry per shipped language (en, nl, de, fr, es, pt). Cues are matched on whole words of the
// folded text (lower case, accents dropped, ß → ss, œ → oe), in every language at once (no language detection).
import Foundation

public enum MemoryCaptureGate {
    public static let maxLineChars = 300
    /// A message longer than this (or with more lines than `longLines`) keeps only its first and last short lines.
    public static let longChars = 1_500
    public static let longLines = 12
    public static let framingLines = 2
    /// What the extraction call reads at most.
    public static let maxExcerptChars = 600

    public struct Language: Sendable {
        /// First-person / durable statements; ignored in a question clause.
        public var statement: [String]
        /// Requests to remember and standing instructions; count everywhere.
        public var anywhere: [String]
        /// "my <relation>": the possessives and the words they must be followed by.
        public var possessives: [String]
        public var relations: [String]
        /// A statement cue followed by one of these words does not count ("I'm trying…", "soy sauce").
        public var notFollowedBy: [String: [String]] = [:]
        /// First words that make a clause of a `?` sentence a question.
        public var questionStarters: [String]
    }

    public static let table: [String: Language] = [
        "en": Language(
            statement: ["i am", "i'm", "my name is", "call me", "i work as", "i work at", "i work in", "i work for", "i live in",
                        "i come from", "i was born", "i prefer", "i like", "i love", "i hate", "i don't like", "i do not like",
                        "i dislike", "i always", "i never", "i usually", "i speak", "i study", "i don't eat", "i can't eat",
                        "i don't drink", "i own", "in future", "in the future", "by default"],
            anywhere: ["from now on", "going forward", "remember that", "remember this", "please remember", "keep in mind",
                       "don't forget", "do not forget", "for future reference", "please always", "always answer", "always use",
                       "always reply", "always respond", "never use", "don't ever", "do not ever", "please never", "stop using"],
            possessives: ["my"],
            relations: ["wife", "husband", "partner", "girlfriend", "boyfriend", "son", "daughter", "kid", "kids", "child", "children",
                        "mother", "mom", "mum", "father", "dad", "sister", "brother", "dog", "cat", "boss", "birthday", "pronouns"],
            notFollowedBy: [
                "i am": ["trying", "getting", "looking", "wondering", "having", "going", "using", "seeing", "thinking", "asking",
                         "talking", "referring", "running", "not", "sorry", "confused", "curious", "stuck", "unsure", "done", "back",
                         "fine", "good", "ok", "okay", "here", "just", "still", "about", "afraid", "glad", "happy", "sure", "unable",
                         "able", "struggling", "facing", "experiencing", "attaching", "sending", "pasting", "sharing", "testing",
                         "debugging", "reading"],
            ],
            questionStarters: ["what", "what's", "who", "who's", "where", "where's", "when", "why", "how", "which", "do", "does", "did",
                               "is", "are", "am", "can", "could", "would", "will", "should", "was", "were", "have", "has"]),
        "nl": Language(
            statement: ["ik ben", "mijn naam is", "ik heet", "noem me", "noem mij", "ik werk als", "ik werk bij", "ik werk in",
                        "ik woon in", "ik kom uit", "ik hou van", "ik houd van", "ik hou niet van", "ik heb liever",
                        "ik geef de voorkeur", "ik wil altijd", "ik wil nooit", "ik eet geen", "ik spreek", "ik studeer"],
            anywhere: ["vanaf nu", "voortaan", "in het vervolg", "onthoud", "vergeet niet", "houd er rekening mee",
                       "hou er rekening mee", "gebruik altijd", "antwoord altijd", "gebruik nooit", "altijd graag"],
            possessives: ["mijn"],
            relations: ["vrouw", "man", "partner", "vriend", "vriendin", "zoon", "dochter", "kind", "kinderen", "moeder", "vader",
                        "zus", "broer", "hond", "kat", "baas", "verjaardag"],
            notFollowedBy: ["ik ben": ["aan", "bezig", "benieuwd", "bang", "niet", "op", "klaar", "er", "het", "even", "nog"]],
            questionStarters: ["wat", "wie", "waar", "wanneer", "waarom", "hoe", "welke", "kun", "kan", "ben", "is", "heb", "weet"]),
        "de": Language(
            statement: ["ich bin", "mein name ist", "ich heisse", "nenn mich", "nenne mich", "ich arbeite als", "ich arbeite bei",
                        "ich arbeite in", "ich wohne in", "ich lebe in", "ich komme aus", "ich bevorzuge", "ich mag", "ich liebe",
                        "ich hasse", "ich esse kein", "ich esse keine", "ich spreche", "ich studiere", "ich will immer",
                        "ich mochte immer", "ich will nie", "in zukunft"],
            anywhere: ["ab jetzt", "ab sofort", "von nun an", "kunftig", "merk dir", "merke dir", "denk daran", "denke daran",
                       "vergiss nicht", "bitte immer", "antworte immer", "verwende immer", "benutze immer", "verwende nie",
                       "bitte nie"],
            possessives: ["mein", "meine"],
            relations: ["frau", "mann", "partner", "partnerin", "freund", "freundin", "sohn", "tochter", "kind", "kinder", "mutter",
                        "vater", "schwester", "bruder", "hund", "katze", "chef", "chefin", "geburtstag"],
            notFollowedBy: ["ich bin": ["mir", "gerade", "dabei", "gespannt", "neugierig", "unsicher", "fertig", "auf", "am", "nicht"]],
            questionStarters: ["was", "wer", "wo", "wann", "warum", "wie", "welche", "kannst", "bin", "ist", "habe", "weisst"]),
        "fr": Language(
            statement: ["je suis", "je m'appelle", "mon nom est", "appelle moi", "appelez moi", "je travaille comme",
                        "je travaille chez", "je travaille dans", "je travaille en", "j'habite", "je vis a", "je vis en",
                        "je viens de", "je prefere", "j'aime", "j'adore", "je n'aime pas", "je deteste", "je ne mange pas",
                        "je parle", "j'etudie", "je veux toujours", "je ne veux jamais", "a l'avenir"],
            anywhere: ["desormais", "dorenavant", "a partir de maintenant", "souviens toi", "souvenez vous", "rappelle toi",
                       "rappelez vous", "retiens que", "retenez que", "n'oublie pas", "n'oubliez pas", "garde en tete",
                       "reponds toujours", "repondez toujours", "utilise toujours", "utilisez toujours", "n'utilise jamais"],
            possessives: ["mon", "ma", "mes"],
            relations: ["femme", "mari", "partenaire", "copain", "copine", "fils", "fille", "enfant", "enfants", "mere", "pere",
                        "soeur", "frere", "chien", "chat", "patron", "patronne", "anniversaire"],
            notFollowedBy: ["je suis": ["en", "desole", "desolee", "perdu", "perdue", "bloque", "bloquee", "curieux", "curieuse", "pas",
                                        "sur"]],
            questionStarters: ["que", "qu'est", "qui", "ou", "quand", "pourquoi", "comment", "quel", "quelle", "est", "peux", "suis"]),
        "es": Language(
            statement: ["soy", "me llamo", "mi nombre es", "llamame", "trabajo como", "trabajo en", "trabajo de", "vivo en",
                        "vengo de", "prefiero", "me gusta", "me gustan", "me encanta", "me encantan", "no me gusta",
                        "no me gustan", "odio", "no como", "hablo", "siempre quiero", "nunca quiero", "en el futuro"],
            anywhere: ["a partir de ahora", "de ahora en adelante", "desde ahora", "en adelante", "recuerda que", "recuerde que",
                       "recuerda esto", "acuerdate", "no olvides", "no olvide", "ten en cuenta", "tenga en cuenta",
                       "responde siempre", "siempre responde", "usa siempre", "siempre usa", "nunca uses", "por favor siempre"],
            possessives: ["mi", "mis"],
            relations: ["esposa", "esposo", "mujer", "marido", "pareja", "novio", "novia", "hijo", "hija", "hijos", "hijas", "madre",
                        "padre", "mama", "papa", "hermana", "hermano", "perro", "gato", "jefe", "jefa", "cumpleanos"],
            notFollowedBy: ["soy": ["sauce", "milk", "bean", "beans", "protein", "products", "lecithin", "oil", "yogurt", "yoghurt",
                                    "flour", "wax", "candle", "candles", "based", "free", "allergy"]],
            questionStarters: ["que", "quien", "donde", "cuando", "por", "como", "cual", "puedes"]),
        "pt": Language(
            statement: ["sou", "me chamo", "chamo me", "meu nome e", "me chame de", "chama me", "trabalho como", "trabalho na",
                        "trabalho no", "trabalho em", "moro em", "moro no", "moro na", "vivo em", "vivo no", "vivo na",
                        "venho de", "prefiro", "gosto de", "nao gosto", "adoro", "odeio", "detesto", "nao como", "falo",
                        "sempre quero", "nunca quero"],
            anywhere: ["a partir de agora", "de agora em diante", "daqui em diante", "daqui para frente", "daqui pra frente",
                       "lembre se", "lembra te", "lembre que", "lembra que", "nao esqueca", "nao te esquecas", "tenha em mente",
                       "leve em conta", "responda sempre", "sempre responda", "use sempre", "sempre use", "nunca use",
                       "por favor sempre"],
            possessives: ["meu", "minha", "meus", "minhas"],
            relations: ["esposa", "esposo", "mulher", "marido", "parceiro", "parceira", "namorado", "namorada", "filho", "filha",
                        "filhos", "filhas", "mae", "pai", "irma", "irmao", "cachorro", "cao", "gato", "chefe", "aniversario"],
            questionStarters: ["que", "quem", "onde", "quando", "por", "como", "qual", "pode", "podes"]),
    ]

    /// The number of cues (statement + anywhere phrases and possessive × relation pairs count once per phrase / relation).
    public static var cueCount: Int { table.values.reduce(0) { $0 + $1.statement.count + $1.anywhere.count + $1.relations.count } }

    public struct Result: Sendable, Equatable {
        /// The cue that fired (diagnostics, tests).
        public var cue: String
        /// The user's own short statements, capped: what the extraction call reads.
        public var excerpt: String
    }

    /// nil = nothing in the message looks lasting: no model call.
    public static func evaluate(_ message: String) -> Result? {
        let own = ownLines(message)
        guard !own.isEmpty else { return nil }
        for line in own {
            for sentence in sentences(strippingQuotes(line)) {
                if let cue = cue(inSentence: sentence.text, question: sentence.question) {
                    return Result(cue: cue, excerpt: String(own.joined(separator: "\n").prefix(maxExcerptChars)))
                }
            }
        }
        return nil
    }

    public static func fires(_ message: String) -> Bool { evaluate(message) != nil }

    // MARK: The user's own statements

    /// The message's short lines without quoted lines and fenced code; of a long message only the framing lines.
    static func ownLines(_ message: String) -> [String] {
        var lines: [String] = []
        var fenced = false
        for raw in message.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced || line.isEmpty || line.hasPrefix(">") { continue }
            lines.append(line)
        }
        let long = message.count > longChars || lines.count > longLines
        if long, lines.count > 2 * framingLines { lines = Array(lines.prefix(framingLines)) + Array(lines.suffix(framingLines)) }
        return lines.filter { $0.count <= maxLineChars }
    }

    static let quotePairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{201E}", "\u{201C}"), ("\u{AB}", "\u{BB}")]

    /// The line without what stands between double quotes (someone else's words, text to translate or correct).
    static func strippingQuotes(_ line: String) -> String {
        var out = line
        for (open, close) in quotePairs {
            while let s = out.firstIndex(of: open), let e = out[out.index(after: s)...].firstIndex(of: close) {
                out.replaceSubrange(s...e, with: " ")
            }
        }
        return out
    }

    static func sentences(_ line: String) -> [(text: String, question: Bool)] {
        var out: [(String, Bool)] = []
        var current = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            let boundary = c == "!" || c == "?" || (c == "." && (i + 1 == chars.count || chars[i + 1].isWhitespace))
            if boundary {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append((current, c == "?")) }
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append((current, false)) }
        return out
    }

    // MARK: Cues

    /// Lower case, accents dropped, ß → ss, œ → oe, typographic apostrophes straightened; words (letters, digits,
    /// inner apostrophes) joined by single spaces.
    static func words(_ text: String) -> [String] {
        let folded = text.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "Œ", with: "oe").replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    private struct Compiled {
        var statement: [(phrase: [String], blocked: Set<String>)] = []
        var anywhere: [[String]] = []
        var possessives: [String: Set<String>] = [:]
        var starters: Set<String> = []
    }

    private static let compiled: Compiled = {
        var c = Compiled()
        for language in table.values {
            for cue in language.statement {
                var blocked = Set(language.notFollowedBy[cue] ?? [])
                // "i'm" follows "i am".
                if cue == "i'm" { blocked = Set(language.notFollowedBy["i am"] ?? []) }
                c.statement.append((cue.split(separator: " ").map(String.init), blocked))
            }
            c.anywhere += language.anywhere.map { $0.split(separator: " ").map(String.init) }
            for p in language.possessives { c.possessives[p, default: []].formUnion(language.relations) }
            c.starters.formUnion(language.questionStarters)
        }
        return c
    }()

    /// The first cue of a sentence. In a `?` sentence the last clause is a question, and so is any clause that starts
    /// with a question word; statement cues do not count there.
    static func cue(inSentence sentence: String, question: Bool) -> String? {
        let clauses = sentence.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == ":" || $0 == "(" || $0 == ")" || $0 == "\u{2014}" })
            .map { words(String($0)) }.filter { !$0.isEmpty }
        let c = compiled
        for (n, w) in clauses.enumerated() {
            if let hit = c.anywhere.first(where: { index(of: $0, in: w) != nil }) { return hit.joined(separator: " ") }
            if question, n == clauses.count - 1 || c.starters.contains(w[0]) { continue }
            for s in c.statement {
                guard let i = index(of: s.phrase, in: w) else { continue }
                let next = i + s.phrase.count < w.count ? w[i + s.phrase.count] : nil
                if let next, s.blocked.contains(next) { continue }
                return s.phrase.joined(separator: " ")
            }
            for i in w.indices.dropLast() {
                if let relations = c.possessives[w[i]], relations.contains(w[i + 1]) { return "\(w[i]) \(w[i + 1])" }
            }
        }
        return nil
    }

    static func index(of phrase: [String], in words: [String]) -> Int? {
        guard !phrase.isEmpty, words.count >= phrase.count else { return nil }
        for i in 0...(words.count - phrase.count) where Array(words[i..<(i + phrase.count)]) == phrase { return i }
        return nil
    }
}
