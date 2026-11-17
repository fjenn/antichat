// M6.T17 (app side, no service needed): the client picks the no-network service unless "Allow network for code"
// is on; the libxpc framing round-trips payloads and descriptors; output files are copied into the app's folder
// under safe, unique names (never overwriting, never following a planted symlink). The service itself is
// exercised by App/IntegrationTests/FileTools (FileToolsJailTests, SecuritySuiteTests).
@testable import AntiChatTools
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation
import Synchronization
import Testing
import XPC

@Suite struct FileToolsClientTests {
    @Test func variantFollowsTheNetworkSettingDefaultOff() {
        let d = UserDefaults.inMemory()
        #expect(FileToolsClient(defaults: d).serviceName == "app.antichat.AntiChat.FileTools.slot1")
        #expect(FileToolsClient(defaults: d).isNetworkVariant == false)
        d.set(true, forKey: FileToolsClient.allowNetworkDefaultsKey)
        #expect(FileToolsClient(defaults: d).serviceName == "app.antichat.AntiChat.FileTools.Net.slot1")
        #expect(FileToolsClient(defaults: d).isNetworkVariant)
        #expect(FileToolsClient(network: false, defaults: d).isNetworkVariant == false)
        #expect(FileToolsClient(network: false, defaults: d).slotClient(3).serviceName == "app.antichat.AntiChat.FileTools.slot3")
        #expect(FileToolsClient(serviceName: "app.antichat.AntiChat.relprobe-adhoc.FileTools.Net.slot2").isNetworkVariant)
    }

    /// RC review P1-1: Offline only always wins over "Allow network for code", and both are read at each call (the
    /// tool's client is made once, when the tool registers).
    @Test func offlineOnlyNeverPicksTheNetworkVariantAndIsReadPerCall() {
        let d = UserDefaults.inMemory()
        d.set(true, forKey: FileToolsClient.allowNetworkDefaultsKey)
        let offline = Mutex(true)
        let c = FileToolsClient(defaults: d, offlineOnly: { offline.withLock { $0 } })
        #expect(!c.isNetworkVariant && c.serviceName == "app.antichat.AntiChat.FileTools.slot1")
        #expect(FileToolsClient(network: true, defaults: d, offlineOnly: { true }).isNetworkVariant == false)
        offline.withLock { $0 = false }
        #expect(c.isNetworkVariant && c.serviceName == "app.antichat.AntiChat.FileTools.Net.slot1")
        d.set(false, forKey: FileToolsClient.allowNetworkDefaultsKey)
        #expect(!c.isNetworkVariant)
    }

    @Test func slotServiceNamesCoverEveryBundle() {
        #expect(FileToolsProtocol.allSlotServiceNames() == [
            "app.antichat.AntiChat.FileTools.slot1", "app.antichat.AntiChat.FileTools.slot2", "app.antichat.AntiChat.FileTools.slot3",
            "app.antichat.AntiChat.FileTools.Net.slot1", "app.antichat.AntiChat.FileTools.Net.slot2", "app.antichat.AntiChat.FileTools.Net.slot3",
        ])
        #expect(!FileToolsProtocol.isNetServiceName("app.antichat.AntiChat.FileTools.slot1"))
        // Debug app = its own ids (one bundle id, one signing identity); everything else the shipped ids.
        #expect(FileToolsProtocol.prefix(forHost: "app.antichat.AntiChat.dev") == "app.antichat.AntiChat.dev")
        #expect(FileToolsProtocol.prefix(forHost: "app.antichat.AntiChat") == "app.antichat.AntiChat")
        #expect(FileToolsProtocol.prefix(forHost: nil) == "app.antichat.AntiChat")
    }

    @Test func wireRoundTripsPayloadAndDescriptors() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ftw-\(UUID().uuidString.prefix(6)).txt")
        try "abc".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fd = open(tmp.path, O_RDONLY)
        let req = RunCode(chatID: "c", code: "print(1)", inputs: [.init(name: "a.txt")], runtimePath: "/r")
        let msg = try FileToolsWire.message(.run, req, fds: [fd])
        close(fd)  // the dictionary holds its own duplicate
        #expect(FileToolsWire.kind(msg) == .run)
        #expect(FileToolsWire.payload(RunCode.self, msg) == req)
        let got = FileToolsWire.fds(msg, prefix: FileToolsWire.inputPrefix)
        #expect(got.count == 1 && got[0] >= 0)
        var buf = [UInt8](repeating: 0, count: 8)
        #expect(read(got[0], &buf, 8) == 3)
        close(got[0])
        #expect(FileToolsWire.fds(msg, prefix: FileToolsWire.outputPrefix).isEmpty)
    }

    @Test func outputsAreCopiedUnderSafeUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ftc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appending(path: "src.bin")
        try Data([1, 2, 3]).write(to: src)
        func copy(_ name: String) throws -> URL {
            let fd = open(src.path, O_RDONLY); defer { close(fd) }
            return try FileToolsClient.copy(fd: fd, name: name, into: dir)
        }
        #expect(try copy("charts/fig.png").lastPathComponent == "fig.png")
        #expect(try copy("fig.png").lastPathComponent == "fig 2.png")
        #expect(try copy(".hidden").lastPathComponent == "output.hidden")
        #expect(try copy("a:b.txt").lastPathComponent == "a_b.txt")
        // A symlink already sitting at the target name is never followed (unique name instead).
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "x.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(try copy("x.txt").lastPathComponent == "x 2.txt")
        #expect(try Data(contentsOf: dir.appending(path: "fig.png")) == Data([1, 2, 3]))
    }

    @Test func aMissingServiceFailsFastWithServiceUnavailable() async {
        // Outside the app bundle no File tools service exists: the call must fail, not hang.
        let client = FileToolsClient(network: false)
        await #expect(throws: FileToolsClientError.self) { _ = try await client.ping() }
    }

    /// A wedged service (accepts the connection, never replies) must not hang the chat: the call fails with
    /// `noReply` at its deadline and the next call uses a fresh connection.
    @Test func aServiceThatNeverRepliesFailsAtTheDeadline() async throws {
        let q = DispatchQueue(label: "ft-test-listener")
        let listener = xpc_connection_create(nil, q)
        let peers = PeerBox()
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            peers.add(peer)
            // Wedged: keep every request alive, never reply (releasing an unanswered request interrupts the caller).
            xpc_connection_set_event_handler(peer) { msg in peers.hold(msg) }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
        defer { xpc_connection_cancel(listener) }
        let client = FileToolsClient(endpoint: xpc_endpoint_create(listener))
        client.controlReplySeconds = 0.5
        client.runReplyGraceSeconds = 0.5
        let t0 = Date()
        await #expect(throws: FileToolsClientError.noReply(seconds: 0.5)) { _ = try await client.ping() }
        let req = RunCode(chatID: "c", code: "1", timeoutS: 0.5, runtimePath: "/r")
        await #expect(throws: FileToolsClientError.noReply(seconds: 1.5)) {
            _ = try await client.run(req, outputDirectory: FileManager.default.temporaryDirectory)
        }
        #expect(Date().timeIntervalSince(t0) < 10)
        #expect(peers.count >= 1)
    }

    final class PeerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var peers: [xpc_connection_t] = []
        private var held: [xpc_object_t] = []
        func add(_ p: xpc_connection_t) { lock.lock(); peers.append(p); lock.unlock() }
        func hold(_ m: xpc_object_t) { lock.lock(); held.append(m); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return peers.count }
    }
}
