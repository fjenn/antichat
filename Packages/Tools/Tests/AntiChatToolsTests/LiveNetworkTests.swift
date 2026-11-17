// Opt-in checks against the real network (skipped unless `ANTICHAT_LIVE=1`): the Skills catalogue's install path
// (raw.githubusercontent.com → SkillsCatalogInstaller → SkillImporter → a temp SkillStore) and the live list of apps
// (the deployed relay's `GET /v1/toolkits` → LiveAppCatalog's merge → AppLogoCache from Composio's logo host).
// Everything is written under `ANTICHAT_LIVE_DIR` (default: the system temp folder) and removed afterwards, except
// `apps-report.txt` there. The relay is asked with a throwaway install ID that is forgotten at the end.
//   ANTICHAT_LIVE=1 ANTICHAT_LIVE_DIR=/tmp/x swift test --filter LiveNetworkTests
import AntiChatFoundation
@testable import AntiChatNetwork
import AntiChatStorage
@testable import AntiChatTools
import AppKit
import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_LIVE"] == "1"))
struct LiveNetworkTests {
    static let relayURL = URL(string: ProcessInfo.processInfo.environment["ANTICHAT_LIVE_RELAY"] ?? "https://antichat-relay.vercel.app")!
    static let version = "0.0.7"

    static func workDir(_ name: String) throws -> URL {
        let base = ProcessInfo.processInfo.environment["ANTICHAT_LIVE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("antichat-live", isDirectory: true)
        let dir = base.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: A. Skills

    /// The index's `hasScripts`, which `SkillsCatalog.Skill` does not decode.
    static func indexedScripts() throws -> [String: Bool] {
        struct Row: Decodable { let id: String; let hasScripts: Bool? }
        struct Index: Decodable { let skills: [Row] }
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AntiChatTools/Resources/skills-index.json").standardizedFileURL
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: file))
        return Dictionary(uniqueKeysWithValues: index.skills.map { ($0.id, $0.hasScripts ?? false) })
    }

    /// Per category one skill with scripts and one without, at least two of every source, and the largest.
    static func sample(_ c: SkillsCatalog, scripts: [String: Bool]) -> [SkillsCatalog.Skill] {
        var picked: [SkillsCatalog.Skill] = []
        func add(_ s: SkillsCatalog.Skill?) { if let s, !picked.contains(where: { $0.id == s.id }) { picked.append(s) } }
        let byID = c.skills.sorted { $0.id < $1.id }
        for cat in c.categories {
            let rows = byID.filter { $0.category == cat.id }
            add(rows.first { scripts[$0.id] == true })
            add(rows.first { scripts[$0.id] != true })
        }
        for source in Set(byID.map { String($0.id.split(separator: "/")[0]) }).sorted() {
            for s in byID.filter({ $0.id.hasPrefix(source + "/") }).prefix(2) { add(s) }
        }
        add(byID.max { $0.files.reduce(0) { $0 + $1.size } < $1.files.reduce(0) { $0 + $1.size } })
        return picked
    }

    @Test(.timeLimit(.minutes(10))) func catalogueSkillsDownloadReviewAndInstall() async throws {
        let dir = try Self.workDir("skills")
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = SkillsCatalog.bundled
        let scripts = try Self.indexedScripts()
        let sample = Self.sample(catalog, scripts: scripts)
        #expect(sample.count >= 12)
        let store = SkillStore(root: dir.appendingPathComponent("Skills", isDirectory: true), database: try AppDatabase.inMemory())
        var failures: [String] = []
        for skill in sample {
            let bytes = skill.files.reduce(0) { $0 + $1.size }
            do {
                let folder = try await SkillsCatalogInstaller.download(skill, temp: dir.appendingPathComponent("dl", isDirectory: true))
                defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
                let candidate = try SkillImporter.inspect(folder)
                guard candidate.canInstall else {
                    candidate.discard()
                    throw SkillImporter.ImportError.unsupported("review: \(candidate.blockingIssue?.message ?? "no SKILL.md document")")
                }
                let warnings = candidate.issues.filter { !$0.blocking }.map(\.message)
                let installed = try SkillImporter.install(candidate, into: store)
                let md = try String(contentsOf: store.directory(for: installed.name).appendingPathComponent("SKILL.md"), encoding: .utf8)
                var problems: [String] = []
                if !installed.isValid { problems.append("invalid: \(installed.invalidReason ?? "?")") }
                if md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("empty SKILL.md") }
                if installed.name != skill.name { problems.append("installed as \(installed.name)") }
                if installed.files.count != skill.files.count { problems.append("\(installed.files.count) files of \(skill.files.count)") }
                if installed.hasScripts != (scripts[skill.id] ?? false) { problems.append("hasScripts \(installed.hasScripts) != index") }
                if store.skill(named: skill.name)?.isValid != true { problems.append("not listed valid in the store") }
                print("LIVE skill \(problems.isEmpty ? "ok  " : "FAIL") \(skill.id) [\(skill.category)] \(skill.files.count) files \(bytes) B"
                      + " scripts=\(installed.hasScripts)\(warnings.isEmpty ? "" : " warnings=\(warnings)")"
                      + (problems.isEmpty ? "" : " \(problems)"))
                if !problems.isEmpty { failures.append("\(skill.id): \(problems.joined(separator: "; "))") }
            } catch {
                print("LIVE skill FAIL \(skill.id) [\(skill.category)] \(error)")
                failures.append("\(skill.id): \(error)")
            }
        }
        print("LIVE skills: \(sample.count - failures.count) of \(sample.count) installed; categories \(Set(sample.map(\.category)).count)"
              + " of \(Set(catalog.skills.map(\.category)).count); with scripts \(sample.filter { scripts[$0.id] == true }.count)")
        #expect(failures.isEmpty, "\(failures)")
    }

    // MARK: B. Apps

    /// How odd a derived summary looks (higher = worse): for the report only.
    static func oddness(_ s: String, name: String) -> Int {
        let words = s.split(separator: " ")
        var n = 0
        if words.count <= 1 { n += 5 } else if words.count == 2 { n += 2 }
        if s.count < 12 { n += 2 }
        if s.lowercased().contains(name.lowercased()) { n += 3 }
        if let last = s.last, !(last.isLetter || last.isNumber || last == ")") { n += 4 }
        if s.filter({ $0 == "(" }).count != s.filter({ $0 == ")" }).count { n += 4 }
        if s.range(of: #"^(Is|Are|A|An|The|It|That|This|To|And|For|With|Which|Your|You)\s"#, options: .regularExpression) != nil { n += 4 }
        if s.range(of: #"\b(is|are|a|an|the|and|or|for|to|with|of|that|your|by|in|on|from)$"#, options: [.regularExpression, .caseInsensitive]) != nil { n += 5 }
        if s.contains(",") && s.count > 38 { n += 1 }
        if s.range(of: #"[.!?]\s"#, options: .regularExpression) != nil { n += 2 }
        return n
    }

    @Test(.timeLimit(.minutes(5))) func theRelaysAppsMergeAndTheirLogosLoad() async throws {
        let dir = try Self.workDir("apps")
        defer { try? FileManager.default.removeItem(at: dir) }
        var report: [String] = []
        func say(_ line: String) { print("LIVE apps: " + line); report.append(line) }

        let secrets = MemorySecrets()
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        let relay = RelayClient(baseURL: Self.relayURL, installID: InstallID(secrets: secrets),
                                session: { NetworkGate.gated(.relay, policy: policy) }, version: Self.version)
        let bundled = ComposioCatalog.bundled
        let logos = AppLogoCache(directory: dir.appendingPathComponent("Logos", isDirectory: true), allowed: { true })
        let live = LiveAppCatalog(directory: dir, relay: relay, bundled: bundled, logos: logos)

        let first = await live.refresh(userOpened: true, force: true)
        // Whatever happens next, the throwaway install is forgotten by the relay.
        func forget() async {
            do { try await relay.forget(); say("forget: ok") } catch { say("forget: \(error)") }
        }
        guard first == .updated else {
            await forget()
            Issue.record("first refresh: \(first.rawValue)")
            return
        }
        #expect(live.isLive)
        let body = try Data(contentsOf: live.fileURL)
        struct File: Decodable { let generated: String; let toolkits: [RelayToolkit] }
        let file = try JSONDecoder().decode(File.self, from: body)
        let raw = file.toolkits
        let catalog = live.catalog

        let second = await live.refresh(userOpened: true, force: true)
        #expect(second == .notModified, "second refresh: \(second.rawValue)")
        #expect(live.catalog.apps == catalog.apps)
        await forget()
        #expect(InstallID(secrets: secrets).existing == nil)

        // Counts
        let rawSlugs = Set(raw.map(\.slug))
        let left = raw.filter { bundled.app($0.slug) == nil
            && (bundled.excluded.contains($0.slug) || $0.auth == "none" || ($0.name + " " + $0.description).lowercased().contains("deprecated")) }
        let expected = Set(raw.map(\.slug)).count - Set(left.map(\.slug)).count
        say("relay: \(raw.count) toolkits (\(body.count) bytes, generated \(file.generated)); auth \(Dictionary(grouping: raw, by: \.auth).mapValues(\.count).sorted { $0.key < $1.key })")
        say("shown: \(catalog.apps.count) (expected \(expected); left out \(left.count): \(left.filter { bundled.excluded.contains($0.slug) }.count) excluded,"
            + " \(left.filter { $0.auth == "none" }.count) no sign-in, \(left.filter { ($0.name + " " + $0.description).lowercased().contains("deprecated") }.count) deprecated)")
        #expect(abs(catalog.apps.count - expected) * 10 <= expected)
        #expect(Set(catalog.apps.map(\.slug)).count == catalog.apps.count, "duplicate slugs")

        let kept = catalog.apps.filter { bundled.app($0.slug) != nil }
        let new = catalog.apps.filter { bundled.app($0.slug) == nil }
        let gone = bundled.apps.filter { !rawSlugs.contains($0.slug) }
        say("bundled \(bundled.apps.count): still offered \(kept.count), disappeared \(gone.count): \(gone.prefix(20).map(\.slug).joined(separator: " "))")
        say("new \(new.count): \(new.prefix(20).map(\.slug).joined(separator: " "))")

        // Curated entries stay ours
        for app in kept { #expect(app == bundled.app(app.slug), "\(app.slug)") }
        // No-sign-in apps only when curated
        for t in raw where t.auth == "none" && bundled.app(t.slug) == nil { #expect(catalog.app(t.slug) == nil, "\(t.slug)") }
        for slug in bundled.excluded where bundled.app(slug) == nil { #expect(catalog.app(slug) == nil, "\(slug)") }

        // Derived entries
        let known = Set(catalog.categories.map(\.id))
        var bad: [String] = []
        for app in new {
            if app.summary.isEmpty { bad.append("\(app.slug): empty summary") }
            if app.summary.count > AppSummary.limit { bad.append("\(app.slug): \(app.summary.count) chars") }
            if app.summary.hasSuffix(".") { bad.append("\(app.slug): full stop") }
            if app.name.isEmpty { bad.append("\(app.slug): no name") }
            if app.categories.count != 1 || !known.isSuperset(of: app.categories) { bad.append("\(app.slug): categories \(app.categories)") }
        }
        say("derived entries with a problem: \(bad.count)\(bad.isEmpty ? "" : ": " + bad.prefix(40).joined(separator: " | "))")
        #expect(bad.isEmpty)
        let distribution = Dictionary(grouping: new, by: { $0.categories.first ?? "?" }).mapValues(\.count).sorted { $0.value > $1.value }
        say("new by category: " + distribution.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let unmapped = Dictionary(grouping: raw.filter { t in new.contains { $0.slug == t.slug && $0.categories == ["other"] } }
            .flatMap { $0.categories.map { $0.lowercased() } }.filter { bundled.categoryMap[$0] == nil }, by: { $0 }).mapValues(\.count)
        say("Composio categories of the apps in other that the map does not have: "
            + unmapped.sorted { $0.value > $1.value }.prefix(25).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        say("new without a logo URL: \(new.filter { $0.logoURL == nil }.count); logo hosts: "
            + "\(Dictionary(grouping: raw.filter { bundled.app($0.slug) == nil }, by: { URL(string: $0.logo)?.host() ?? "-" }).mapValues(\.count))")
        say("15 oddest derived summaries:")
        let descriptions = Dictionary(raw.map { ($0.slug, $0.description) }, uniquingKeysWith: { a, _ in a })
        for app in new.sorted(by: { (Self.oddness($0.summary, name: $0.name), $0.slug) > (Self.oddness($1.summary, name: $1.name), $1.slug) }).prefix(15) {
            say("  \(app.slug) | \(app.name) | \(app.summary) <= \(String((descriptions[app.slug] ?? "").prefix(140)))")
        }
        report.append("ALL DERIVED:")
        for app in new { report.append("  \(app.slug)\t\(app.categories.first ?? "")\t\(app.name)\t\(app.summary)\t<= \(String((descriptions[app.slug] ?? "").prefix(160)))") }

        // Logos: what the row does (AppLogo): the cache's bytes into NSImage.
        // Composio answers an app without a logo with its placeholder, which the cache refuses (the initial shows).
        var loaded: [ComposioCatalog.App] = [], tried = 0
        for app in new where app.logoURL != nil && loaded.count < 5 && tried < 15 {
            tried += 1
            let data = await logos.logo(slug: app.slug, url: app.logoURL!)
            let image = data.flatMap { NSImage(data: $0) }
            let kind = data.map { d -> String in
                if d.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
                if d.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
                if d.starts(with: Array("GIF8".utf8)) { return "gif" }
                if d.starts(with: Array("RIFF".utf8)) { return "webp" }
                return String(decoding: d.prefix(2000), as: UTF8.self).contains("<svg") ? "svg" : "other"
            } ?? "none (placeholder or failure)"
            let ok = image?.isValid == true && (image?.size.width ?? 0) > 0
            say("logo \(app.slug): \(app.logoURL!.absoluteString) -> \(data?.count ?? 0) bytes \(kind) image=\(ok)"
                + " size=\(image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-")")
            if data != nil { #expect(ok, "\(app.slug)") }
            if ok { loaded.append(app) }
        }
        say("logos: \(loaded.count) of \(tried) tried became an image")
        #expect(loaded.count == 5)
        let picks = loaded
        // And from the folder the second time (no request).
        if let app = picks.first, let url = app.logoURL {
            let offline = AppLogoCache(directory: dir.appendingPathComponent("Logos", isDirectory: true), allowed: { false })
            #expect(await offline.logo(slug: app.slug, url: url) != nil)
        }

        if let out = ProcessInfo.processInfo.environment["ANTICHAT_LIVE_DIR"] {
            try? report.joined(separator: "\n").write(to: URL(fileURLWithPath: out).appendingPathComponent("apps-report.txt"), atomically: true, encoding: .utf8)
        }
    }
}
