// Updates for catalogue skills (SkillProvenance.swift): the record written on a catalogue install (beside the
// skill, never in it), the once-only adoption of skills installed before there was a record, when an update is
// offered (another file set in the index AND an untouched installed copy), the swap that keeps the switches and puts
// everything back on failure, and which updates need the review sheet. A stub loader stands in for the network;
// every store is a temp folder over an in-memory database.
@testable import AntiChatTools
import AntiChatStorage
import CryptoKit
import Foundation
import Testing

@Suite struct SkillUpdateTests {
    typealias Files = [String: String]

    static let v1: Files = ["SKILL.md": "---\nname: brand-voice\ndescription: Writes in the brand's voice.\n---\nBe brief.\n",
                            "reference/tone.md": "Warm and plain.\n"]
    static let v2: Files = ["SKILL.md": "---\nname: brand-voice\ndescription: Writes in the brand's voice.\n---\nBe brief and kind.\n",
                            "reference/words.md": "Say it simply.\n"]

    static func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func entry(_ files: Files, name: String = "brand-voice", commit: Character = "a") -> SkillsCatalog.Skill {
        let c = String(repeating: commit, count: 40)
        return SkillsCatalog.Skill(id: "example/\(name)", name: name, title: "Brand voice", category: "writing", author: "Example",
                                   license: "Apache-2.0", commit: c,
                                   base: "https://raw.githubusercontent.com/example/skills/\(c)/skills/\(name)/",
                                   files: files.keys.sorted().map { .init(path: $0, sha256: sha(files[$0]!), size: files[$0]!.utf8.count) })
    }

    static func catalog(_ skills: SkillsCatalog.Skill...) -> SkillsCatalog {
        SkillsCatalog(categories: [.init(id: "writing", title: "Writing")], skills: skills, generated: "2026-11-17")
    }

    /// Serves `files` of `entry` (what raw.githubusercontent.com would).
    static func loader(_ entry: SkillsCatalog.Skill, _ files: Files) -> SkillsCatalogInstaller.Loader {
        { url in
            guard url.absoluteString.hasPrefix(entry.base), let body = files[String(url.absoluteString.dropFirst(entry.base.count))]
            else { return (Data(), 404) }
            return (Data(body.utf8), 200)
        }
    }

    /// The ordinary catalogue path: download + verify, inspect, then install or update.
    static func candidate(_ entry: SkillsCatalog.Skill, _ files: Files, temp: URL) async throws -> SkillImportCandidate {
        let folder = try await SkillsCatalogInstaller.download(entry, temp: temp, loader: loader(entry, files))
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return try SkillImporter.inspect(folder)
    }

    /// A folder with `files`, as the user's own source.
    static func folder(_ files: Files, name: String, in temp: URL) throws -> URL {
        let dir = temp.appendingPathComponent("src-\(UUID().uuidString)/\(name)", isDirectory: true)
        for (path, body) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    static func tree(_ dir: URL) -> Files {
        Dictionary(uniqueKeysWithValues: SkillStore.files(in: dir).map {
            ($0.relativePath, (try? String(contentsOf: dir.appendingPathComponent($0.relativePath), encoding: .utf8)) ?? "")
        })
    }

    /// What the Skills root holds besides the skills and the records (a stage or a backup left behind).
    static func strays(_ t: TempSkillStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: t.store.root.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != SkillProvenance.folder }
    }

    @Test func aCatalogueInstallRecordsWhereItCameFromBesideTheSkill() async throws {
        let t = try TempSkillStore(); defer { t.cleanup() }
        let e = Self.entry(Self.v1)
        try SkillImporter.install(try await Self.candidate(e, Self.v1, temp: t.dir), into: t.store, source: e)
        #expect(t.store.provenance(of: "brand-voice") == SkillProvenance(id: "example/brand-voice", commit: e.commit,
                                                                         digest: SkillProvenance.digest(of: e)))
        // The skill's folder is exactly what the catalogue lists: it validates, and exports as it was.
        #expect(Self.tree(t.store.directory(for: "brand-voice")) == Self.v1)
        try t.store.reconcile()
        #expect(t.store.list().map(\.name) == ["brand-voice"], "the records folder is no skill")
        #expect(t.store.skill(named: "brand-voice")?.isValid == true)
        let zip = t.dir.appendingPathComponent("out.zip")
        #expect(try SkillExporter.export("brand-voice", from: t.store, to: zip).isEmpty)
        #expect(t.store.availableUpdates(in: Self.catalog(e)).isEmpty)
        // The user's own file under that name: no longer the catalogue's skill.
        try SkillImporter.install(try SkillImporter.inspect(try Self.folder(Self.v1, name: "brand-voice", in: t.dir)), into: t.store)
        #expect(t.store.provenance(of: "brand-voice") == nil)
        // Delete takes the record along.
        try SkillImporter.install(try await Self.candidate(e, Self.v1, temp: t.dir), into: t.store, source: e)
        try t.store.delete("brand-voice")
        #expect(t.store.provenance(of: "brand-voice") == nil)
    }

    @Test func skillsFromBeforeTheRecordAreAdoptedOnceByNameAndFiles() throws {
        let t = try TempSkillStore(); defer { t.cleanup() }
        let old = Self.entry(Self.v1), new = Self.entry(Self.v2, commit: "b")
        let mine: Files = ["SKILL.md": "---\nname: memo\ndescription: My own memo skill.\n---\nShort.\n"]
        let theirs: Files = ["SKILL.md": "---\nname: memo\ndescription: Writes memos.\n---\nShort.\n"]
        try t.store.install(from: try Self.folder(Self.v1, name: "brand-voice", in: t.dir), name: "brand-voice", trust: .user)
        try t.store.install(from: try Self.folder(mine, name: "memo", in: t.dir), name: "memo", trust: .user)
        // Without an index nothing is decided yet.
        t.store.adoptCatalogSkills(from: [SkillsCatalog(data: nil)])
        #expect(t.store.provenance(of: "brand-voice") == nil)
        // The index in use has moved on; the one this build shipped still lists the installed files.
        t.store.adoptCatalogSkills(from: [Self.catalog(new, Self.entry(theirs, name: "memo")), Self.catalog(old)])
        #expect(t.store.provenance(of: "brand-voice") == SkillProvenance(id: old.id, commit: old.commit, digest: SkillProvenance.digest(of: old)))
        #expect(t.store.provenance(of: "memo") == nil, "same name, other files: the user's own")
        #expect(Array(t.store.availableUpdates(in: Self.catalog(new, Self.entry(theirs, name: "memo"))).keys) == ["brand-voice"])
        // Once: a skill added later without a record stays the user's own, whatever its files.
        try t.store.install(from: try Self.folder(theirs, name: "memo", in: t.dir), name: "memo", trust: .user)
        t.store.adoptCatalogSkills(from: [Self.catalog(Self.entry(theirs, name: "memo"))])
        #expect(t.store.provenance(of: "memo") == nil)
    }

    @Test func anUpdateIsOfferedForAnotherFileSetAndAnUntouchedCopyOnly() async throws {
        let t = try TempSkillStore(); defer { t.cleanup() }
        let e = Self.entry(Self.v1), newer = Self.entry(Self.v2, commit: "b")
        try SkillImporter.install(try await Self.candidate(e, Self.v1, temp: t.dir), into: t.store, source: e)
        try t.store.install(from: try Self.folder(["SKILL.md": "---\nname: mine\ndescription: Mine.\n---\nHi.\n"], name: "mine", in: t.dir),
                            name: "mine", trust: .user)
        let mine = SkillsCatalog.Skill(id: "example/mine", name: "mine", title: "Mine", commit: newer.commit, base: newer.base,
                                       files: [.init(path: "SKILL.md", sha256: Self.sha("other"), size: 5)])
        #expect(t.store.availableUpdates(in: Self.catalog(newer, mine)) == ["brand-voice": newer], "never for the user's own skill")
        #expect(t.store.availableUpdates(in: Self.catalog(Self.entry(Self.v1, commit: "c"))).isEmpty, "a new commit, the same files")
        #expect(t.store.availableUpdates(in: Self.catalog(mine)).isEmpty, "no longer in the index")
        // Looking at the folder in Finder is not an edit.
        let dir = t.store.directory(for: "brand-voice")
        try Data([0, 1]).write(to: dir.appendingPathComponent(".DS_Store"))
        #expect(t.store.availableUpdates(in: Self.catalog(newer)).count == 1)
        // The user's edit: the copy is theirs now, and stays.
        try "Warm, plain and mine.\n".write(to: dir.appendingPathComponent("reference/tone.md"), atomically: true, encoding: .utf8)
        try t.store.reconcile()
        #expect(t.store.availableUpdates(in: Self.catalog(newer)).isEmpty)
    }

    @Test func anUpdateReplacesTheFilesAndKeepsTheSwitches() async throws {
        let t = try TempSkillStore(); defer { t.cleanup() }
        let e = Self.entry(Self.v1), newer = Self.entry(Self.v2, commit: "b")
        try SkillImporter.install(try await Self.candidate(e, Self.v1, temp: t.dir), into: t.store, source: e)
        try t.store.setEnabled("brand-voice", false)
        try t.store.setApplyAll("brand-voice", true)
        let before = try #require(t.store.skill(named: "brand-voice"))
        let updated = try SkillImporter.update(try await Self.candidate(newer, Self.v2, temp: t.dir), into: t.store, source: newer)
        #expect(Self.tree(t.store.directory(for: "brand-voice")) == Self.v2, "the old version's files are gone")
        #expect(!updated.record.enabled && updated.record.applyAll && updated.record.id == before.record.id && updated.record.trust == .user)
        #expect(updated.record.contentHash != before.record.contentHash && updated.document?.body == "Be brief and kind.")
        #expect(t.store.provenance(of: "brand-voice") == SkillProvenance(id: newer.id, commit: newer.commit, digest: SkillProvenance.digest(of: newer)))
        #expect(t.store.availableUpdates(in: Self.catalog(newer)).isEmpty)
        #expect(Self.strays(t).isEmpty)
    }

    @Test func aFailedUpdateLeavesTheOldCopy() async throws {
        let t = try TempSkillStore(); defer { t.cleanup() }
        let e = Self.entry(Self.v1), newer = Self.entry(Self.v2, commit: "b")
        try SkillImporter.install(try await Self.candidate(e, Self.v1, temp: t.dir), into: t.store, source: e)
        try t.store.setEnabled("brand-voice", false)
        let before = try #require(t.store.skill(named: "brand-voice")), record = t.store.provenance(of: "brand-voice")
        // A download that is not the listed one never gets as far as the store.
        await #expect(throws: SkillsCatalogInstaller.Failure.hashMismatch(path: "SKILL.md")) {
            var served = Self.v2
            served["SKILL.md"] = String(served["SKILL.md"]!.dropLast(2)) + "!\n"
            _ = try await Self.candidate(newer, served, temp: t.dir)
        }
        // New files that are no valid skill of that name: refused before anything moves.
        let other = try Self.folder(["SKILL.md": "---\nname: other-name\ndescription: Not it.\n---\nNo.\n"], name: "brand-voice", in: t.dir)
        #expect(throws: SkillStore.UpdateError.self) { try t.store.update("brand-voice", from: other, source: newer) }
        #expect(throws: SkillStore.UpdateError.notInstalled("nope")) { try t.store.update("nope", from: other, source: newer) }
        #expect(Self.tree(t.store.directory(for: "brand-voice")) == Self.v1 && t.store.provenance(of: "brand-voice") == record)
        // A failure after the new folder is in place (the record cannot be written): the old folder and row come back.
        let fm = FileManager.default
        let json = t.store.root.appendingPathComponent("\(SkillProvenance.folder)/brand-voice.json")
        try fm.removeItem(at: json)
        try fm.createDirectory(at: json.appendingPathComponent("in-the-way"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try SkillImporter.update(try SkillImporter.inspect(try Self.folder(Self.v2, name: "brand-voice", in: t.dir)), into: t.store, source: newer)
        }
        #expect(Self.tree(t.store.directory(for: "brand-voice")) == Self.v1)
        let after = try #require(t.store.skill(named: "brand-voice"))
        #expect(after.record.contentHash == before.record.contentHash && after.record.manifestJSON == before.record.manifestJSON)
        #expect(!after.record.enabled && after.isValid)
        #expect(Self.strays(t).isEmpty)
    }

    @Test func onlyScriptsAndAllowedToolsNeedAReview() async throws {
        let t = try TempSkillStore(); defer { t.cleanup() }
        func md(_ tools: String?, _ body: String) -> String {
            "---\nname: brand-voice\ndescription: Writes in the brand's voice.\n\(tools.map { "allowed-tools: \($0)\n" } ?? "")---\n\(body)\n"
        }
        let base: Files = ["SKILL.md": md("web_search", "One."), "scripts/a.py": "print(1)\n", "scripts/b.py": "print(2)\n"]
        let e = Self.entry(base)
        try SkillImporter.install(try await Self.candidate(e, base, temp: t.dir), into: t.store, source: e)
        let installed = try #require(t.store.skill(named: "brand-voice")), dir = t.store.directory(for: "brand-voice")
        func change(_ files: Files) async throws -> SkillUpdateChange? {
            let c = try await Self.candidate(Self.entry(files, commit: "b"), files, temp: t.dir)
            defer { c.discard() }
            return SkillUpdateChange.between(installed: installed, in: dir, candidate: c)
        }
        var text = base
        text["SKILL.md"] = md("web_search", "Two.")
        text["reference/more.md"] = "More.\n"
        #expect(try await change(text) == nil, "text only")
        var fewer = text
        fewer["scripts/b.py"] = nil
        #expect(try await change(fewer) == nil, "a script less is nothing new to run")
        var edited = base
        edited["scripts/a.py"] = "print(3)\n"
        #expect(try await change(edited) == .scripts)
        var added = base
        added["scripts/c.py"] = "print(4)\n"
        #expect(try await change(added) == .scripts)
        var tools = base
        tools["SKILL.md"] = md("web_search gmail", "One.")
        #expect(try await change(tools) == .tools)
        tools["scripts/c.py"] = "print(4)\n"
        #expect(try await change(tools) == .both)
    }
}
