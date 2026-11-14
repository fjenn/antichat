// SkillSelector (M7.T13 step 1; R-262, R-263; P-files-tools-16): which installed skills a request may need. Ported from
// osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Services/Skill/SkillSearchService.swift (MIT):
//   - index text = name + description (`buildIndexText`; the instructions stay out of the index: workflow prose, not
//     intent vocabulary), embedded once per content hash and stored in `skill.embedding` (v29_skill_flags) instead of
//     a VecturaKit store — at ≤ 100 skills a linear cosine pass over the stored vectors is ~µs, so no vec0 index;
//   - the lexical fallback (`searchLiveSkillsLexically`: name ×3 + description ×1 token overlap over the query's tokens
//     of ≥ 3 letters) when no embedding model is installed or the embed call fails (R-295: never an error).
// Changes: no shared actor or MainActor skill list (the caller passes the candidates), scores come back for every
// candidate (the eval tunes θ and M), and ties break by name so the manifest order is stable (K-NEW-TOOLS-2).
import AntiChatStorage
import Foundation

public struct SkillSelector: Sendable {
    /// Embeds `texts` as queries (`query == true`) or documents; nil = no model (lexical scores are used).
    public typealias Embed = @Sendable (_ texts: [String], _ query: Bool) async -> [[Float]]?

    public struct Scored: Sendable, Hashable {
        public var name: String
        public var description: String
        /// Cosine similarity (embeddings) or the lexical score, 0…1.
        public var score: Double
        public var semantic: Bool
        public init(name: String, description: String, score: Double, semantic: Bool) {
            self.name = name; self.description = description; self.score = score; self.semantic = semantic
        }
    }

    let embed: Embed?
    public init(embed: Embed?) { self.embed = embed }

    /// Upstream `buildIndexText` (no keywords field in Agent Skills).
    public static func indexText(name: String, description: String) -> String {
        "\(name.replacingOccurrences(of: "-", with: " ")) \(description)"
    }

    /// The best `m` of `candidates` for `message`, highest score first (ties by name). m ≤ 0 → none; capped at 100.
    public func topM(_ message: String, candidates: [InstalledSkill], m: Int, store: SkillStore? = nil) async -> [Scored] {
        Array(await rank(message, candidates: candidates, store: store).prefix(max(0, min(m, 100))))
    }

    /// Every candidate with its score, best first.
    public func rank(_ message: String, candidates: [InstalledSkill], store: SkillStore? = nil) async -> [Scored] {
        let valid = candidates.filter(\.isValid)
        guard !valid.isEmpty else { return [] }
        if let embed, let vectors = await vectors(for: valid, embed: embed, store: store),
           let q = await embed([message], true)?.first, !q.isEmpty {
            let scored = zip(valid, vectors).map { s, v in
                Scored(name: s.name, description: s.description, score: v.count == q.count ? Self.cosine(q, v) : 0, semantic: true)
            }
            return Self.sorted(scored)
        }
        let qTokens = Self.tokens(message)
        return Self.sorted(valid.map { s in
            Scored(name: s.name, description: s.description, score: Self.lexical(qTokens, name: s.name, description: s.description),
                   semantic: false)
        })
    }

    static func sorted(_ xs: [Scored]) -> [Scored] {
        xs.sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    /// Stored vectors for the candidates; missing or stale ones (the hash stored with the vector differs from the row's
    /// content hash: the folder was edited) are embedded in one call and written back.
    func vectors(for skills: [InstalledSkill], embed: Embed, store: SkillStore?) async -> [[Float]]? {
        var out: [[Float]?] = skills.map { s in
            guard let data = s.record.embedding, let (hash, v) = Self.decode(data), hash == s.record.contentHash else { return nil }
            return v
        }
        let missing = out.indices.filter { out[$0] == nil }
        if !missing.isEmpty {
            let texts = missing.map { Self.indexText(name: skills[$0].name, description: skills[$0].description) }
            guard let fresh = await embed(texts, false), fresh.count == missing.count else { return nil }
            for (i, v) in zip(missing, fresh) {
                out[i] = v
                try? store?.setEmbedding(skills[i].name, Self.encode(v, hash: skills[i].record.contentHash))
            }
        }
        let all = out.compactMap { $0 }
        guard all.count == skills.count, let dim = all.first?.count, all.allSatisfy({ $0.count == dim }) else { return nil }
        return all
    }

    // MARK: Scores

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// Upstream `lexicalScore` without keywords: (name hits × 3 + description hits) / (query tokens × 3), ≤ 1.
    static func lexical(_ q: Set<String>, name: String, description: String) -> Double {
        guard !q.isEmpty else { return 0 }
        let weighted = q.intersection(tokens(name)).count * 3 + q.intersection(tokens(description)).count
        return min(1, Double(weighted) / Double(max(q.count * 3, 1)))
    }

    /// Upstream `searchTokens`: lowercased letter/number runs of ≥ 3 characters.
    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    // MARK: Storage (`skill.embedding`: 64 hex chars of the content hash, then little-endian Float32s)

    static func encode(_ v: [Float], hash: String) -> Data {
        var d = Data(hash.utf8.prefix(64))
        if d.count < 64 { d.append(Data(repeating: 0x20, count: 64 - d.count)) }
        for f in v { withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    static func decode(_ d: Data) -> (String, [Float])? {
        guard d.count > 64, (d.count - 64) % 4 == 0 else { return nil }
        let hash = String(decoding: d.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let body = d.dropFirst(64)
        var v: [Float] = []
        v.reserveCapacity(body.count / 4)
        var i = body.startIndex
        while i < body.endIndex {
            let bits = body[i..<i + 4].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) }
            v.append(Float(bitPattern: bits))
            i += 4
        }
        return (hash, v)
    }
}

extension SkillStore {
    /// M7.T13: the selector's cached description vector (see `SkillSelector.encode`).
    public func setEmbedding(_ name: String, _ data: Data?) throws {
        try repository.update(name) { $0.embedding = data }
    }
}
