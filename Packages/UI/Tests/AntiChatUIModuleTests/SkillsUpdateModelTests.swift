// Settings → Skills, "Update" (in-process): an installed catalogue skill with a newer version in the index is offered
// an update; pressing it downloads through the catalogue installer (a stub loader here: every size and hash is still
// checked) and replaces the copy without a sheet when only text changed, after Review skill when scripts or
// allowed-tools did; on / off stays; a failure leaves the old copy and one plain line; Offline only sends nothing.
import AntiChatDesign
import AntiChatStorage
import AntiChatTools
import CryptoKit
import Foundation
import Testing
@testable import AntiChatUI

@MainActor @Suite(.serialized, .isolatedSettings) struct SkillsUpdateModelTests {
    typealias Files = [String: String]

    static func md(_ name: String, _ body: String, tools: String? = nil) -> String {
        "---\nname: \(name)\ndescription: Does \(name).\n\(tools.map { "allowed-tools: \($0)\n" } ?? "")---\n\(body)\n"
    }

    static func entry(_ name: String, _ files: Files, commit: Character) -> SkillsCatalog.Skill {
        let c = String(repeating: commit, count: 40)
        func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        return SkillsCatalog.Skill(id: "example/\(name)", name: name, title: name, category: "writing", author: "Example",
                                   license: "MIT", commit: c, base: "https://raw.githubusercontent.com/example/skills/\(c)/\(name)/",
                                   files: files.keys.sorted().map { .init(path: $0, sha256: sha(files[$0]!), size: files[$0]!.utf8.count) })
    }

    /// What the stub "network" serves, and every URL that was asked for.
    final class Net: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String: Data] = [:]
        private var asked: [URL] = []
        var requests: [URL] { lock.withLock { asked } }
        func serve(_ entry: SkillsCatalog.Skill, _ files: Files) {
            lock.withLock { for (path, body) in files { bodies[entry.base + path] = Data(body.utf8) } }
        }
        func drop(_ entry: SkillsCatalog.Skill, _ path: String) { lock.withLock { bodies[entry.base + path] = nil } }
        var loader: SkillsCatalogInstaller.Loader {
            { url in
                self.lock.withLock {
                    self.asked.append(url)
                    return self.bodies[url.absoluteString].map { ($0, 200) } ?? (Data(), 404)
                }
            }
        }
    }

    struct World {
        let library: SkillsLibrary
        let store: SkillStore
        let dir: URL
        let net = Net()

        /// A library over a temp store; `installed` are put there the way `+` and Install do.
        @MainActor init(installed: [(SkillsCatalog.Skill, Files)], index: [SkillsCatalog.Skill]) async throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("skills-update-model-\(UUID().uuidString)", isDirectory: true)
            store = SkillStore(root: dir.appendingPathComponent("Skills", isDirectory: true), database: try AppDatabase.inMemory())
            let net = net, dir = dir, store = store
            library = SkillsLibrary(observe: false, store: { store })
            library.download = { try await SkillsCatalogInstaller.download($0, temp: dir, loader: net.loader) }
            library.offlineOnly = { false }
            for (entry, files) in installed {
                net.serve(entry, files)
                await library.installFromCatalog(entry)
                library.install()
            }
            library.catalog = { SkillsCatalog(categories: [.init(id: "writing", title: "Writing")], skills: index, generated: "2026-11-17") }
            library.reload()
        }

        func text(_ name: String, _ path: String = "SKILL.md") -> String? {
            try? String(contentsOf: store.directory(for: name).appendingPathComponent(path), encoding: .utf8)
        }

        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    static let notes1: Files = ["SKILL.md": md("notes", "One."), "reference/a.md": "A.\n"]
    static let notes2: Files = ["SKILL.md": md("notes", "Two."), "reference/b.md": "B.\n"]

    @Test func aTextOnlyUpdateIsAppliedWithoutReviewAndKeepsTheSwitch() async throws {
        let old = Self.entry("notes", Self.notes1, commit: "a"), new = Self.entry("notes", Self.notes2, commit: "b")
        let w = try await World(installed: [(old, Self.notes1)], index: [new]); defer { w.cleanup() }
        #expect(w.store.provenance(of: "notes")?.commit == old.commit, "Install from the catalogue records its source")
        #expect(w.library.updates == ["notes": new])
        w.library.setEnabled("notes", false)
        let before = w.net.requests.count
        w.library.reload()
        #expect(w.net.requests.count == before, "seeing that there is an update asks the network nothing")
        w.net.serve(new, Self.notes2)
        await w.library.update("notes")
        #expect(w.library.reviewing == nil && w.library.updateErrors.isEmpty && w.library.updating.isEmpty)
        #expect(w.text("notes") == Self.notes2["SKILL.md"] && w.text("notes", "reference/b.md") == "B.\n" && w.text("notes", "reference/a.md") == nil)
        #expect(w.library.skills.first { $0.name == "notes" }?.record.enabled == false, "off stays off")
        #expect(w.library.updates.isEmpty && w.store.provenance(of: "notes")?.commit == new.commit)
    }

    @Test func anUpdateThatChangesScriptsOrToolsIsReviewedFirst() async throws {
        let v1: Files = ["SKILL.md": Self.md("runner", "One."), "scripts/run.py": "print(1)\n"]
        let v2: Files = ["SKILL.md": Self.md("runner", "One.", tools: "web_search"), "scripts/run.py": "print(2)\n"]
        let old = Self.entry("runner", v1, commit: "a"), new = Self.entry("runner", v2, commit: "b")
        let w = try await World(installed: [(old, v1)], index: [new]); defer { w.cleanup() }
        w.net.serve(new, v2)
        await w.library.update("runner")
        let c = try #require(w.library.reviewing)
        #expect(c.name == "runner" && w.library.reviewingChange == .both && w.library.reviewingSource == new)
        #expect(w.text("runner", "scripts/run.py") == "print(1)\n", "nothing is replaced before the review")
        // Cancel: the old copy stays, the update is still on offer.
        w.library.cancelReview()
        w.library.reload()
        #expect(w.library.reviewing == nil && w.library.reviewingChange == nil && w.library.updates["runner"] == new)
        #expect(w.text("runner", "scripts/run.py") == "print(1)\n")
        // Review, then [Update].
        w.library.setEnabled("runner", false)
        await w.library.update("runner")
        #expect(w.library.reviewingChange == .both)
        w.library.install()
        #expect(w.library.reviewing == nil && w.library.reviewingChange == nil && w.library.updates.isEmpty)
        #expect(w.text("runner", "scripts/run.py") == "print(2)\n")
        #expect(w.library.skills.first { $0.name == "runner" }?.record.enabled == false)
    }

    @Test func aFailedUpdateLeavesTheInstalledCopyAndSaysSoInOneLine() async throws {
        let old = Self.entry("notes", Self.notes1, commit: "a"), new = Self.entry("notes", Self.notes2, commit: "b")
        let w = try await World(installed: [(old, Self.notes1)], index: [new]); defer { w.cleanup() }
        await w.library.update("notes")  // nothing served: 404
        #expect(w.library.updateErrors == ["notes": "Couldn't update this skill. Try again."])
        var wrong = Self.notes2
        wrong["reference/b.md"] = "b.\n"  // the listed size, other bytes
        w.net.serve(new, wrong)
        await w.library.update("notes")
        #expect(w.library.updateErrors == ["notes": "This update didn't match its listing, so nothing was changed."])
        #expect(w.text("notes") == Self.notes1["SKILL.md"] && w.text("notes", "reference/a.md") == "A.\n")
        #expect(w.library.updates["notes"] == new && w.library.updating.isEmpty && w.store.provenance(of: "notes")?.commit == old.commit)
        #expect(w.library.skills.first { $0.name == "notes" }?.isValid == true)
        // The next try works, and the line goes.
        w.net.serve(new, Self.notes2)
        await w.library.update("notes")
        #expect(w.library.updateErrors.isEmpty && w.text("notes") == Self.notes2["SKILL.md"])
    }

    @Test func offlineOnlyOffersTheUpdateButSendsNothing() async throws {
        let old = Self.entry("notes", Self.notes1, commit: "a"), new = Self.entry("notes", Self.notes2, commit: "b")
        let w = try await World(installed: [(old, Self.notes1)], index: [new]); defer { w.cleanup() }
        w.net.serve(new, Self.notes2)
        w.library.offlineOnly = { true }
        w.library.reload()
        #expect(w.library.offline && w.library.updates["notes"] == new)
        let before = w.net.requests.count
        await w.library.update("notes")
        await w.library.updateAll()
        #expect(w.net.requests.count == before && w.text("notes") == Self.notes1["SKILL.md"] && w.library.updateErrors.isEmpty)
        w.library.offlineOnly = { false }
        w.library.reload()
        #expect(!w.library.offline)
    }

    @Test func updateAllTakesEveryUntouchedCatalogueSkillAndLeavesTheUsersOwn() async throws {
        let other1: Files = ["SKILL.md": Self.md("letters", "One.")], other2: Files = ["SKILL.md": Self.md("letters", "Two.")]
        let edited1: Files = ["SKILL.md": Self.md("memo", "One.")], edited2: Files = ["SKILL.md": Self.md("memo", "Two.")]
        let old = [Self.entry("notes", Self.notes1, commit: "a"), Self.entry("letters", other1, commit: "a"), Self.entry("memo", edited1, commit: "a")]
        let new = [Self.entry("notes", Self.notes2, commit: "b"), Self.entry("letters", other2, commit: "b"), Self.entry("memo", edited2, commit: "b"),
                   Self.entry("own", ["SKILL.md": Self.md("own", "Theirs.")], commit: "b")]
        let w = try await World(installed: [(old[0], Self.notes1), (old[1], other1), (old[2], edited1)], index: new); defer { w.cleanup() }
        // The user's own skill of a name the catalogue has, and their edit of a catalogue skill: neither is offered.
        let src = w.dir.appendingPathComponent("src/own", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Self.md("own", "Mine.").write(to: src.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        w.library.beginImport(src)
        w.library.install()
        try Self.md("memo", "My way.").write(to: w.store.directory(for: "memo").appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        w.library.reload()
        #expect(w.library.updates.keys.sorted() == ["letters", "notes"])
        w.net.serve(new[0], Self.notes2)
        w.net.serve(new[1], other2)
        await w.library.updateAll()
        #expect(w.library.updates.isEmpty && w.library.updateErrors.isEmpty)
        #expect(w.text("notes") == Self.notes2["SKILL.md"] && w.text("letters") == other2["SKILL.md"])
        #expect(w.text("memo") == Self.md("memo", "My way.") && w.text("own") == Self.md("own", "Mine."))
    }
}
