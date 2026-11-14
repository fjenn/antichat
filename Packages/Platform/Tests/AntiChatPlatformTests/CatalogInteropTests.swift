// M2.T05 AT-220 part 2 (P-platform-02 interop): Sparkle's `sign_update` output verifies with CryptoKit, both for
// our fixture (fixtures/catalog/catalog-valid.json.sparkle.sig, made by Sparkle 2.10.1 `sign_update --ed-key-file
// … -p`) and for Sparkle's own Ed25519 test vector.
// Ported from sparkle-project/Sparkle@2.10.1 (ab7d712) Tests/SUSignatureVerifierTest.m (MIT): public key,
// Tests/Resources/signed-test-file.txt ("Hello World!\n") and its valid / invalid EdDSA signatures.
@testable import AntiChatPlatform
import CryptoKit
import Foundation
import Testing

@Suite struct CatalogInteropTests {
    @Test func sparkleSignatureOfFixtureVerifies() throws {
        let data = try CatalogFixtures.data("catalog-valid.json")
        let sparkle = try CatalogFixtures.data("catalog-valid.json.sparkle.sig")
        #expect(CatalogVerifier().verify(data: data, sig: sparkle))
        // Ed25519 is deterministic: Sparkle's signature equals the one catalog-tool wrote.
        let cryptoKit = try CatalogFixtures.data("catalog-valid.json.sig")
        #expect(CatalogVerifier().verify(data: data, sig: cryptoKit))
    }

    @Test func sparkleTestVector() {
        let verifier = CatalogVerifier(base64Keys: ["rhHib+w769W2/6/t+oM1ZxgjBB93BfBKMLO0Qo1etQs="])
        let file = Data("Hello World!\n".utf8)
        let valid = Data("EIawm2YkDZ2gBfkEMF2+1VuuTeXnCGZOdnMdVgPPvDZioq7bvDayXqKkIIzSjKMmeFdcFJOHdnba5ZV60+gPBw==".utf8)
        let invalid = Data("wTcpXCgWoa4NrJpsfzS61FXJIbv963//12U2ef9xstzVOLPHYK2N4/ojgpDV5N1/NGG1uWMBgK+kEWp0Z5zMDQ==".utf8)
        #expect(verifier.verify(data: file, sig: valid))
        #expect(!verifier.verify(data: file, sig: invalid))
        #expect(!verifier.verify(data: Data("Hello World?\n".utf8), sig: valid))
        #expect(!CatalogVerifier().verify(data: file, sig: valid))  // not one of our pinned keys
    }
}
