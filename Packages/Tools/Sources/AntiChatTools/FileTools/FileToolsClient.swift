// App side of the File tools sandbox (M6.T17 step 4–6; R-018 AC2; A-M6-11). Talks libxpc to the embedded
// AntiChatFileToolsSlot<k>.xpc (no network) or, only when "Allow network for code" is on, AntiChatFileToolsNetSlot<k>.xpc,
// in the slot `FileToolsSlots` leases to the call's chat (A-M6-T21a (a): one chat per slot container).
// Inputs go over as read-only file descriptors the app opens on its own files; outputs come back as descriptors
// the service opened on its jail's `out/` files, and the app copies them into a folder of ITS choosing (the
// media store, T19). The app never names, opens or writes a path inside the service's container.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import Darwin
import Foundation
import Synchronization
import XPC

public enum FileToolsClientError: Error, Equatable, Sendable {
    /// The service could not be reached or died during the call (connection interrupted / invalid).
    case serviceUnavailable(String)
    case badReply
    case versionMismatch(service: Int, app: Int)
    case input(String)
    /// No reply within the call's deadline (the service is wedged); the connection is dropped so the next call
    /// starts a new one, and the caller sees an error instead of waiting forever.
    case noReply(seconds: Double)
}

public final class FileToolsClient: @unchecked Sendable {
    /// UserDefaults key of Settings → Tools & Connections "Allow network for code" (row in M6.T19); default off.
    public static let allowNetworkDefaultsKey = "allowNetworkForCode"

    /// The service this client talks to directly; for a slot-routed client the variant's slot 1 (ping's target).
    public var serviceName: String {
        fixedServiceName ?? FileToolsProtocol.slotServiceName(1, network: network, prefix: slots?.prefix ?? FileToolsProtocol.servicePrefix)
    }
    private let fixedServiceName: String?
    /// RC review P1-1: a routed client decides its variant at each call: the setting as it is now, and never the
    /// network variant while Offline only is on (the Net service's sockets do not pass through NetworkGate).
    public var network: Bool { networkNow() }
    private let networkNow: @Sendable () -> Bool
    public var isNetworkVariant: Bool { network }
    /// Slot routing (A-M6-T21a (a)): every chat call goes to the slot leased to its chat. nil = `serviceName` directly
    /// (one slot's own client, tests' in-process listener).
    public let slots: FileToolsSlots?
    private let queue = DispatchQueue(label: "filetools.client")
    private let lock = NSLock()
    private var connection: xpc_connection_t?
    private var slotClients: [String: FileToolsClient] = [:]
    /// Tests: connect to this endpoint (an in-process anonymous listener) instead of the named service.
    private let endpoint: xpc_endpoint_t?
    /// Tests: shorter deadlines.
    var controlReplySeconds = FileToolsClient.controlReplySeconds
    var runReplyGraceSeconds = FileToolsClient.runReplyGraceSeconds

    /// `network` picks the variant; nil reads the setting (`allowNetworkForCode`, default false). Calls are routed to
    /// the slot `slots` leases to their chat.
    /// `offlineOnly`: the Offline only switch (default: the app's network policy), read at each call.
    public init(network: Bool? = nil, defaults: UserDefaults = AppDefaults.standard, slots: FileToolsSlots = .shared,
                offlineOnly: @escaping @Sendable () -> Bool = { NetworkPolicyStore.shared.offlineOnly }) {
        nonisolated(unsafe) let d = defaults
        networkNow = { (network ?? d.bool(forKey: FileToolsClient.allowNetworkDefaultsKey)) && !offlineOnly() }
        self.slots = slots
        fixedServiceName = nil
        endpoint = nil
    }

    /// One service, no routing: a slot's own client (the leaser's wipe, tests that address one slot).
    public init(serviceName: String) {
        fixedServiceName = serviceName
        let net = FileToolsProtocol.isNetServiceName(serviceName)
        networkNow = { net }
        slots = nil
        endpoint = nil
    }

    /// Tests only: a client of an in-process listener (`xpc_endpoint_create`).
    init(endpoint: xpc_endpoint_t) {
        fixedServiceName = FileToolsProtocol.slotServiceName(1, network: false)
        networkNow = { false }
        slots = nil
        self.endpoint = endpoint
    }

    /// The direct client of slot `slot` of this client's variant (connections are kept per slot).
    func slotClient(_ slot: Int, network net: Bool? = nil) -> FileToolsClient {
        let name = FileToolsProtocol.slotServiceName(slot, network: net ?? network, prefix: slots?.prefix ?? FileToolsProtocol.servicePrefix)
        lock.lock(); defer { lock.unlock() }
        if let c = slotClients[name] { return c }
        let c = FileToolsClient(serviceName: name)
        c.controlReplySeconds = controlReplySeconds
        c.runReplyGraceSeconds = runReplyGraceSeconds
        slotClients[name] = c
        return c
    }

    deinit { if let c = connection { xpc_connection_cancel(c) } }

    private func conn() -> xpc_connection_t {
        lock.lock(); defer { lock.unlock() }
        if let c = connection { return c }
        let c = endpoint.map { xpc_connection_create_from_endpoint($0) } ?? xpc_connection_create(serviceName, queue)
        if endpoint != nil { xpc_connection_set_target_queue(c, queue) }
        xpc_connection_set_event_handler(c) { [weak self] event in
            // Invalid = the service is gone for good (or never existed): drop it so the next call reconnects.
            if xpc_get_type(event) == XPC_TYPE_ERROR, event === XPC_ERROR_CONNECTION_INVALID {
                self?.lock.lock(); self?.connection = nil; self?.lock.unlock()
            }
        }
        xpc_connection_resume(c)
        connection = c
        return c
    }

    /// An XPC reply crossing from the connection queue to the awaiting task (it is never mutated after).
    private struct Reply: @unchecked Sendable { let object: xpc_object_t }

    /// Grace beyond a run's own wall-clock limit: interpreter start (≤ 30 s ready wait), input copy-in, output
    /// hand-out. The service kills code at its deadline; this bounds the app's wait if the service itself wedges.
    public static let runReplyGraceSeconds: Double = 45
    /// Deadline of the control calls (ping, reset).
    public static let controlReplySeconds: Double = 15

    /// Sends `message` and waits at most `timeout` seconds for the reply. A missed deadline cancels the
    /// connection (in-flight replies then arrive as errors and are ignored) and throws `noReply`.
    private func call(_ message: xpc_object_t, timeout: Double) async throws -> xpc_object_t {
        let c = conn()
        let once = Once()
        let reply: Reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Reply, Error>) in
            xpc_connection_send_message_with_reply(c, message, queue) { reply in
                guard once.claim() else { return }
                if let e = FileToolsWire.errorDescription(reply) {
                    cont.resume(throwing: FileToolsClientError.serviceUnavailable(e))
                } else {
                    cont.resume(returning: Reply(object: reply))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard once.claim() else { return }
                self?.drop(c)
                cont.resume(throwing: FileToolsClientError.noReply(seconds: timeout))
            }
        }
        return reply.object
    }

    /// Forgets and cancels `c` (a wedged connection); the next call reconnects (launchd restarts the service).
    private func drop(_ c: xpc_connection_t) {
        lock.lock()
        if let cur = connection, cur === c { connection = nil }
        lock.unlock()
        xpc_connection_cancel(c)
    }

    /// First caller wins (reply vs. deadline).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    // MARK: Calls

    /// Handshake: the service's protocol version must equal ours. A routed client pings slot `slot` (default 1).
    public func ping(slot: Int = 1) async throws -> FileToolsPong {
        if slots != nil { return try await slotClient(slot).ping() }
        let reply = try await call(try FileToolsWire.message(.ping, FileToolsPing()), timeout: controlReplySeconds)
        guard let pong = FileToolsWire.payload(FileToolsPong.self, reply) else { throw FileToolsClientError.badReply }
        guard pong.protocolVersion == FileToolsProtocol.version else {
            throw FileToolsClientError.versionMismatch(service: pong.protocolVersion, app: FileToolsProtocol.version)
        }
        return pong
    }

    /// Runs code; `inputs[i]` is sent (read-only descriptor) as `request.inputs[i]`. Output files are copied into
    /// `outputDirectory` (created if needed; names made unique) and returned in `RunResult.outFiles` order.
    /// `waitKey` (the tool call id) is listed by `FileToolsSlots.isWaiting` while the call waits for a free slot.
    public func run(_ request: RunCode, inputs: [URL] = [], outputDirectory: URL, waitKey: String? = nil) async throws -> (RunResult, [URL]) {
        if let slots {
            let net = network  // one decision per call: the lease and the service agree
            let lease = try await slots.acquire(chatID: request.chatID, network: net, waitKey: waitKey)
            do {
                let r = try await slotClient(lease.slot, network: net).run(request, inputs: inputs, outputDirectory: outputDirectory)
                await slots.release(lease)
                return r
            } catch {
                await slots.release(lease)
                throw error
            }
        }
        guard inputs.count == request.inputs.count else { throw FileToolsClientError.input("inputs and request.inputs differ in count") }
        var fds: [Int32] = []
        defer { for fd in fds { close(fd) } }
        for u in inputs {
            let fd = open(u.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw FileToolsClientError.input("cannot open \(u.lastPathComponent): \(String(cString: strerror(errno)))") }
            fds.append(fd)
        }
        let reply = try await call(try FileToolsWire.message(.run, request, fds: fds),
                                   timeout: max(1, request.timeoutS) + runReplyGraceSeconds)
        guard let result = FileToolsWire.payload(RunResult.self, reply) else { throw FileToolsClientError.badReply }
        let outFDs = FileToolsWire.fds(reply, prefix: FileToolsWire.outputPrefix)
        defer { for fd in outFDs where fd >= 0 { close(fd) } }
        var urls: [URL] = []
        if !result.outFiles.isEmpty {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }
        for (i, out) in result.outFiles.enumerated() where i < outFDs.count && outFDs[i] >= 0 {
            urls.append(try Self.copy(fd: outFDs[i], name: out.name, into: outputDirectory))
        }
        return (result, urls)
    }

    /// Chat deleted, incognito ended, Evil wipe (review #6): ends each chat's interpreter and deletes its jail in the
    /// slot it holds, and gives the slot up. Chats that never ran code cost nothing (no service launch).
    public static func release(chatIDs: [String], slots: FileToolsSlots = .shared) {
        guard !chatIDs.isEmpty else { return }
        Task.detached {
            for chat in chatIDs {
                guard let held = await slots.holding(chat) else { continue }
                for net in held.variants {
                    _ = try? await FileToolsClient(serviceName: FileToolsProtocol.slotServiceName(held.slot, network: net, prefix: slots.prefix))
                        .reset(chatID: chat)
                }
                await slots.forget(chat)
                await SessionIdleReaper.shared.cancel(chatID: chat)
            }
        }
    }

    /// Ends the chat's interpreter and deletes its jail in the service (routed: in the slot the chat holds, every
    /// variant it used there; a chat without a slot has nothing to reset).
    @discardableResult
    public func reset(chatID: String) async throws -> Bool {
        if let slots {
            guard let held = await slots.holding(chatID) else { return false }
            var existed = false
            for net in held.variants {
                existed = try await FileToolsClient(serviceName: FileToolsProtocol.slotServiceName(held.slot, network: net, prefix: slots.prefix))
                    .reset(chatID: chatID) || existed
            }
            return existed
        }
        return try await resetAck(chatID: chatID).existed
    }

    /// The reset call itself (direct clients); `wipeSlot` ends every session of the service (a lease move).
    public func resetAck(chatID: String, wipeSlot: Bool = false) async throws -> ResetAck {
        let reply = try await call(try FileToolsWire.message(.reset, ResetSession(chatID: chatID, wipeSlot: wipeSlot)), timeout: controlReplySeconds)
        guard let ack = FileToolsWire.payload(ResetAck.self, reply) else { throw FileToolsClientError.badReply }
        return ack
    }

    /// M7's R-265 hook: skill scripts run only after the caller presents `skills.scriptApproval` and records approval.
    /// The script crosses into the jail as a read-only input descriptor, exactly like a `run_python` attachment.
    public func runScript(skillID: String, scriptPath: URL, args: [String], chatID: String, runtimePath: String,
                          policy: ScriptPolicy = .requireApproval, approved: Bool = false,
                          outputDirectory: URL) async throws -> (RunResult, [URL]) {
        if policy == .requireApproval && !approved { throw ScriptApprovalRequired(skillID: skillID) }
        // Python literals (review #10: a JSON "\/" is not a Python escape, so "in/x.py" became "in\/x.py").
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
        let encodedArgs = String(decoding: try e.encode(args), as: UTF8.self)
        let name = scriptPath.lastPathComponent
        let path = Self.pythonLiteral("in/" + name)
        let code = "import runpy, sys\nsys.argv = \(encodedArgs)\nrunpy.run_path(\(path), init_globals={'__name__': '__main__'})"
        let request = RunCode(chatID: chatID, code: code, inputs: [.init(name: name)], runtimePath: runtimePath)
        return try await run(request, inputs: [scriptPath], outputDirectory: outputDirectory)
    }

    /// A Python string literal for `s`: a JSON string is one, except that Python has no `\/` escape, so slashes are
    /// never escaped (review #10/#12). Shared with `EditOfficeFileTool`.
    static func pythonLiteral(_ s: String) -> String {
        let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? e.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: Output copy (app side)

    /// The display name for an output (`charts/fig.png` → `fig.png`), safe as a single path component.
    public static func outputFileName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? "output"
        let cleaned = last.replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.hasPrefix(".") { return "output" + cleaned }
        return String(cleaned.prefix(200))
    }

    /// Copies the descriptor's content into `dir/<name>` (never overwrites: `name 2.ext`, …).
    static func copy(fd: Int32, name: String, into dir: URL) throws -> URL {
        let fm = FileManager.default
        let base = outputFileName(name)
        var url = dir.appending(path: base)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let ext = (base as NSString).pathExtension, stem = (base as NSString).deletingPathExtension
            url = dir.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        let out = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard out >= 0 else { throw FileToolsClientError.input("cannot create \(url.lastPathComponent)") }
        defer { close(out) }
        _ = lseek(fd, 0, SEEK_SET)
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if r < 0 { if errno == EINTR { continue }; throw FileToolsClientError.input("read \(name)") }
            if r == 0 { break }
            var off = 0
            while off < r {
                let w = buf.withUnsafeBytes { write(out, $0.baseAddress! + off, r - off) }
                if w < 0 { if errno == EINTR { continue }; throw FileToolsClientError.input("write \(name)") }
                off += w
            }
        }
        return url
    }
}

/// M7's R-265 hook (M6.T19 step 5): a skill script runs only after the caller showed the `skills.scriptApproval`
/// ApprovalCard and the user allowed it (`FileToolsClient.runScript(..., approved: true)`).
public enum ScriptPolicy: String, Sendable {
    case requireApproval
}

public struct ScriptApprovalRequired: Error, Sendable, Equatable {
    public let skillID: String
    public let copyKey = "skills.scriptApproval"
    public init(skillID: String) { self.skillID = skillID }
}
