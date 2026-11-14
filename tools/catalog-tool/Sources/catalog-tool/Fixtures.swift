// M2.T04 step 7 (environment §4): signed fixture catalogs for CatalogStore/selector/update tests, derived from the
// built catalog so they share its real assignments. Dates are fixed (tests inject `now`); all are signed with key A.
import Foundation

enum Fixtures {
    static func date(_ s: String) -> String { s + "T00:00:00Z" }

    static func run(from base: Manifest, out: URL, keyFile: String, signUpdate: URL?) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var valid = base
        valid.catalog_version = 100; valid.issued = date("2026-11-01"); valid.expires = date("2027-01-30"); valid.revoked = []

        var expired = valid
        expired.catalog_version = 101; expired.issued = date("2026-01-01"); expired.expires = date("2026-04-01")

        var rollback = valid
        rollback.catalog_version = 99

        var revoked = valid
        revoked.catalog_version = 102
        revoked.revoked = [Revocation(id: "chat-9b-q4", action: "disable", reason: "takedown"),
                           Revocation(id: "chat-4b", action: "warn", reason: "license")]

        // T11 (AT-294): a config-only update of the starter, superseding chat-0.8b.
        var upgrade = valid
        upgrade.catalog_version = 110
        if var starter = valid.models["chat-0.8b"] {
            starter.supersedes = ["chat-0.8b"]
            starter.release_notes = "Answers a little faster."
            if let i = starter.files.firstIndex(where: { $0.path == "config.json" }) {
                starter.files[i].sha256 = String(repeating: "a", count: 64)
            }
            upgrade.models["chat-0.8b-v2"] = starter
            for (k, classes) in upgrade.assignments {
                for (sc, var c) in classes { c.chat.fast_first = "chat-0.8b-v2"; upgrade.assignments[k]?[sc] = c }
            }
        }
        var badsha = upgrade
        badsha.catalog_version = 111
        if var m = badsha.models["chat-0.8b-v2"], let i = m.files.indices.max(by: { m.files[$0].size < m.files[$1].size }) {
            m.files[i].sha256 = String(repeating: "0", count: 64); badsha.models["chat-0.8b-v2"] = m
        }
        var big = upgrade
        big.catalog_version = 112
        if var m = big.models["chat-0.8b-v2"], let i = m.files.indices.max(by: { m.files[$0].size < m.files[$1].size }) {
            m.files[i].size = 5_000_000_000_000; big.models["chat-0.8b-v2"] = m
        }

        let sets: [(String, Manifest)] = [("catalog-valid", valid), ("catalog-expired", expired), ("catalog-rollback", rollback),
                                          ("catalog-revoked", revoked), ("catalog-upgrade", upgrade),
                                          ("catalog-upgrade-badsha", badsha), ("catalog-upgrade-big", big)]
        for (name, m) in sets {
            let url = out.appending(path: name + ".json")
            try m.encoded().write(to: url)
            try Sign.run(file: url, keyFile: keyFile, signUpdate: nil)
        }
        // bad-sig: the valid catalog's signature over bytes with one byte flipped (still decodes).
        let validURL = out.appending(path: "catalog-valid.json")
        var bytes = try Data(contentsOf: validURL)
        if let r = bytes.range(of: Data("Answer directly".utf8)) { bytes[r.lowerBound] = UInt8(ascii: "B") }
        try bytes.write(to: out.appending(path: "catalog-bad-sig.json"))
        try Data(contentsOf: out.appending(path: "catalog-valid.json.sig")).write(to: out.appending(path: "catalog-bad-sig.json.sig"))
        // Interop vector: Sparkle's own sign_update over the valid catalog (CatalogInteropTests verifies it with CryptoKit).
        if let tool = signUpdate {
            let sig = try Sign.sparkleSignature(file: validURL, keyFile: keyFile, tool: tool)
            try (sig.base64EncodedString() + "\n").write(to: out.appending(path: "catalog-valid.json.sparkle.sig"), atomically: true, encoding: .utf8)
        }
        print("fixtures: wrote \(sets.count + 1) catalogs to \(out.path)")
    }
}
