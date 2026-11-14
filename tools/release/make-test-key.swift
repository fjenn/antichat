// tools/release/make-test-key.swift — Ed25519 TEST key for Sparkle / catalog tests (M0.T12 step 5; ci-release.md §6.1
// "Test keys"). No Keychain: Sparkle's generate_keys stores into the login Keychain and makes sign_update raise an
// access dialog (PRD §1.5). Output format = what `generate_keys -x` exports: line 1 the base64 32-byte private seed,
// line 2 the base64 public key (SUPublicEDKey).
// Usage: swift tools/release/make-test-key.swift > fixtures/catalog/test-keys/sparkle-test.key   (then split, see appcast-test.sh)
import CryptoKit

let k = Curve25519.Signing.PrivateKey()
print(k.rawRepresentation.base64EncodedString())
print(k.publicKey.rawRepresentation.base64EncodedString())
