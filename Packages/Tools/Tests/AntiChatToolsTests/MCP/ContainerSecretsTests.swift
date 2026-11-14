// Q-015 r3: a throwaway dev container keeps its secrets in the container, never in the login keychain (an item an
// earlier ad-hoc build left there opened a blocking password prompt on every read: Composio Connect hung silently).
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct ContainerSecretsTests {
    @Test func aDevContainerKeepsSecretsInItsOwnFileOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = KeychainSecrets(containerPath: dir.path)
        let service = "app.antichat.test.\(UUID().uuidString)"  // never created in the keychain by this test
        #expect(s.read(service: service, account: "token") == nil)
        try s.write("v1", service: service, account: "token")
        #expect(KeychainSecrets(containerPath: dir.path).read(service: service, account: "token") == "v1", "persists in the container")
        #expect(KeychainSecrets(containerPath: nil).read(service: service, account: "token") == nil, "not in the keychain")
        let file = dir.appending(path: "Secrets/secrets.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        s.delete(service: service, account: "token")
        #expect(s.read(service: service, account: "token") == nil)
    }

    @Test func outsideADevContainerItIsTheKeychain() {
        #expect(KeychainSecrets().container == nil, "unit-test process: no -ANTICHAT_DEV_CONTAINER")
    }
}
