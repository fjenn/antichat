// M2.T05 (R-220 AC1, NFR-SEC7; P-platform-02): negative vectors. Ported from
// QuintinShaw/openasr@08c5c9a:crates/openasr-core/tests/fixtures/catalog_incident/* (Apache-2.0, copied unchanged
// to fixtures/catalog/incident/ with its LICENSE): a full catalog and its public subset, each signed under a foreign
// Ed25519 key. Every combination must be refused, and a refused catalog never replaces the last good one.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct CatalogIncidentVectorTests {
    struct OpenASRSignature: Decodable {
        struct Sig: Decodable { var algorithm: String; var value: String }
        var signature: Sig
    }

    func vector(_ name: String) throws -> (catalog: Data, sigHex: String, sigBase64: Data) {
        let catalog = try CatalogFixtures.data("incident/\(name).json")
        let s = try JSONDecoder().decode(OpenASRSignature.self, from: CatalogFixtures.data("incident/\(name).signature.json"))
        var raw = Data()
        var hex = Substring(s.signature.value)
        while hex.count >= 2 { raw.append(UInt8(hex.prefix(2), radix: 16)!); hex = hex.dropFirst(2) }
        #expect(raw.count == 64 && s.signature.algorithm == "ed25519")
        return (catalog, s.signature.value, Data(raw.base64EncodedString().utf8))
    }

    @Test func foreignKeyRejected() throws {
        for name in ["full_catalog", "public_catalog"] {
            let v = try vector(name)
            #expect(!CatalogVerifier().verify(data: v.catalog, sig: v.sigBase64), "\(name)")
            #expect(!CatalogVerifier().verify(data: v.catalog, sig: Data(v.sigHex.utf8)), "\(name) hex")
        }
    }

    @Test func swappedPairsRejected() throws {
        let full = try vector("full_catalog"), pub = try vector("public_catalog")
        #expect(!CatalogVerifier().verify(data: full.catalog, sig: pub.sigBase64))
        #expect(!CatalogVerifier().verify(data: pub.catalog, sig: full.sigBase64))
        // Our genuine catalog with a foreign signature, and a foreign catalog with our genuine signature.
        let ours = try CatalogFixtures.pair("catalog-valid")
        #expect(!CatalogVerifier().verify(data: ours.0, sig: full.sigBase64))
        #expect(!CatalogVerifier().verify(data: full.catalog, sig: ours.1))
    }

    @Test func malformedSignaturesRejected() throws {
        let ours = try CatalogFixtures.pair("catalog-valid")
        let good = String(decoding: ours.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["", "not base64!", String(good.dropLast(4)), Data(repeating: 0, count: 64).base64EncodedString(),
                    Data(repeating: 0, count: 63).base64EncodedString(), good + good] {
            #expect(!CatalogVerifier().verify(data: ours.0, sig: Data(bad.utf8)), "\(bad.prefix(12))")
        }
    }

    @Test func foreignSchemaNeverDecodes() throws {
        #expect(throws: (any Error).self) { try ModelCatalog.decode(CatalogFixtures.data("incident/full_catalog.json")) }
    }

    @Test func refusedVectorNeverReplacesLastGood() async throws {
        let server = FixtureServer()
        server.serve(try CatalogFixtures.pair("catalog-valid"))
        let store = CatalogStore.fixture(server: server, cache: CatalogFixtures.tempDir())
        await store.refresh()
        let v = try vector("full_catalog")
        server.serve((v.catalog, v.sigBase64))
        #expect(await store.refresh() == .badSignature)
        #expect(store.catalog?.catalogVersion == 100)
    }
}
