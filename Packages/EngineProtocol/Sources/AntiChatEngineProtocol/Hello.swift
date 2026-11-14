// Handshake (architecture.md §4.3; M1.T05 step 1): Hello{protocolVersion, appBuild} →
// HelloAck{protocolVersion, capabilities}. A mismatch → `ServerMessage.helloRejected(engine.versionMismatch)`,
// then the helper exits.
import AntiChatFoundation
import Foundation

public struct Hello: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var appBuild: String
    /// M9.T05 (NFR-B5): the client's own pid, so the helper's GPU-yield sampler never counts AntiChat's own window
    /// (its UI and previews) as "another app". Optional: an older client leaves it out.
    public var clientPID: Int32?

    public init(protocolVersion: Int = EngineProtocolVersion.current, appBuild: String, clientPID: Int32? = getpid()) {
        self.protocolVersion = protocolVersion
        self.appBuild = appBuild
        self.clientPID = clientPID
    }
}

public struct HelloAck: Codable, Sendable, Hashable {
    public var protocolVersion: Int
    public var capabilities: EngineCapabilities
    /// The helper's pid (restart measurement, orphan checks, XPCHandshakeTests).
    public var helperPID: Int32
    /// `MTLDevice.recommendedMaxWorkingSetSize` of the helper's default device (K-002).
    public var recommendedMaxWorkingSetSize: UInt64
    /// M4.T04 (R-291 AC2): random per helper launch. A `running` media job row stamped with another instance is `lost`.
    public var engineInstanceID: String

    public init(
        protocolVersion: Int = EngineProtocolVersion.current, capabilities: EngineCapabilities, helperPID: Int32,
        recommendedMaxWorkingSetSize: UInt64, engineInstanceID: String = ""
    ) {
        self.engineInstanceID = engineInstanceID
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.helperPID = helperPID
        self.recommendedMaxWorkingSetSize = recommendedMaxWorkingSetSize
    }
}

extension AntiChatError {
    /// The helper's answer to a Hello of another protocol version.
    public static func versionMismatch(helper: Int, app: Int) -> AntiChatError {
        AntiChatError(.engineVersionMismatch, detail: "helper \(helper) app \(app)")
    }
}
