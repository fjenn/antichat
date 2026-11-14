// AntiChatFileTools[Net]Slot<k>.xpc entry (M6.T17; A-M6-T21a (a); architecture §1.2, §4 row 5). Every slot runs
// this code; only their entitlements differ (FileToolsNet adds network.client). The service is App-Sandboxed:
// it sees its own container plus the read-only Runtimes folders (A-M6-11), never the AntiChat database, the
// Keychain items of the app or the user's files. Messages (FileToolsWire): ping → pong, run → result + output
// descriptors, reset → ack. Every request is handled off the connection queue, so chats run in parallel.
import AntiChatEngineProtocol
import Darwin
import Foundation
import XPC

public final class FileToolsService: @unchecked Sendable {
    public let pool: SessionPool
    public let network: Bool
    private let work = DispatchQueue(label: "filetools.work", attributes: .concurrent)
    private let idleTimer: DispatchSourceTimer
    nonisolated(unsafe) static var shared: FileToolsService?

    public init(network: Bool, jail: Jail = .default()) {
        self.network = network
        pool = SessionPool(jail: jail, network: network)
        idleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "filetools.idle"))
    }

    /// The variant from the bundle id (`…FileTools.Net.slot<k>` = network on; A-M6-T21a (a)).
    public static var isNetVariant: Bool { Bundle.main.bundleIdentifier.map(FileToolsProtocol.isNetServiceName) ?? false }

    /// True when this process runs in an App Sandbox container.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || NSHomeDirectory().contains("/Library/Containers/")
    }

    /// Starts serving (never returns): `xpc_main` with this service as the handler.
    public func runForever() -> Never {
        signal(SIGPIPE, SIG_IGN)  // a dead interpreter's pipe must never kill the service
        Self.shared = self
        pool.jail.removeAll()  // review #6: nothing from an earlier service process (sessions never survive it)
        // A-M6-03: sessions idle 10 min end; with none left for 10 min the service exits (launchd restarts it on demand).
        idleTimer.schedule(deadline: .now() + 30, repeating: 30)
        idleTimer.setEventHandler { [pool] in
            pool.reapIdle()
            if pool.sessionCount == 0, pool.idleFor >= FileToolsProtocol.idleSeconds { pool.jail.removeAll(); try? FileManager.default.removeItem(at: pool.jail.root); exit(0) }
        }
        idleTimer.resume()
        xpc_main { connection in
            FileToolsService.shared?.accept(connection)
        }
    }

    func accept(_ connection: xpc_connection_t) {
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard let self else { return }
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
                self.work.async { self.handle(event, on: connection) }
            }
        }
        xpc_connection_resume(connection)
    }

    func handle(_ msg: xpc_object_t, on connection: xpc_connection_t) {
        guard let kind = FileToolsWire.kind(msg) else { return }
        switch kind {
        case .ping:
            let pong = FileToolsPong(protocolVersion: FileToolsProtocol.version, pid: getpid(), sandboxed: Self.isSandboxed,
                                     network: network, sessions: pool.sessionCount)
            send(try? FileToolsWire.reply(to: msg, pong), on: connection)
        case .run:
            let inputs = FileToolsWire.fds(msg, prefix: FileToolsWire.inputPrefix)
            defer { for fd in inputs where fd >= 0 { close(fd) } }
            guard let req = FileToolsWire.payload(RunCode.self, msg) else {
                send(try? FileToolsWire.reply(to: msg, RunResult(serviceError: "undecodable request")), on: connection)
                return
            }
            guard !inputs.contains(-1) else {
                send(try? FileToolsWire.reply(to: msg, RunResult(serviceError: "missing input descriptor")), on: connection)
                return
            }
            let (result, outFDs) = pool.run(req, inputFDs: inputs)
            defer { for fd in outFDs { close(fd) } }
            send(try? FileToolsWire.reply(to: msg, result, fds: outFDs), on: connection)
        case .reset:
            // A lease moving to another chat (wipeSlot) ends every session and deletes every jail first.
            let req = FileToolsWire.payload(ResetSession.self, msg)
            let existed = req.map { $0.wipeSlot ? pool.wipe() : pool.reset($0.chatID) } ?? false
            send(try? FileToolsWire.reply(to: msg, ResetAck(existed: existed, scratchEmpty: pool.jail.isEmpty)), on: connection)
        }
    }

    private func send(_ reply: xpc_object_t??, on connection: xpc_connection_t) {
        guard let r = reply ?? nil else { return }
        xpc_connection_send_message(connection, r)
    }
}
