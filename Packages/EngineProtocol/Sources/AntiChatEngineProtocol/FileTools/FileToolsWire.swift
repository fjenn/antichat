// libxpc framing of the File tools contract (M6.T17), shared by the app's FileToolsClient and the service so both
// sides build and read the same dictionaries: {"kind", "v", "payload" (JSON), "<prefix>.<i>" file descriptors,
// "<prefix>.count"}. `xpc_dictionary_set_fd` duplicates the descriptor (the sender may close its own right after);
// `xpc_dictionary_dup_fd` hands the receiver a new one it must close.
import Foundation
import XPC

public enum FileToolsWire {
    public static let inputPrefix = "in"
    public static let outputPrefix = "out"

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// A request dictionary.
    public static func message<T: Encodable>(_ kind: FileToolsKind, _ payload: T, fds: [Int32] = []) throws -> xpc_object_t {
        let d = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(d, "kind", kind.rawValue)
        xpc_dictionary_set_int64(d, "v", Int64(FileToolsProtocol.version))
        try fill(d, payload, fds: fds, prefix: inputPrefix)
        return d
    }

    /// The reply to `request` (nil when the sender expects none).
    public static func reply<T: Encodable>(to request: xpc_object_t, _ payload: T, fds: [Int32] = []) throws -> xpc_object_t? {
        guard let d = xpc_dictionary_create_reply(request) else { return nil }
        try fill(d, payload, fds: fds, prefix: outputPrefix)
        return d
    }

    static func fill<T: Encodable>(_ d: xpc_object_t, _ payload: T, fds: [Int32], prefix: String) throws {
        let data = try encoder.encode(payload)
        data.withUnsafeBytes { xpc_dictionary_set_data(d, "payload", $0.baseAddress!, data.count) }
        xpc_dictionary_set_int64(d, "\(prefix).count", Int64(fds.count))
        for (i, fd) in fds.enumerated() { xpc_dictionary_set_fd(d, "\(prefix).\(i)", fd) }
    }

    public static func kind(_ d: xpc_object_t) -> FileToolsKind? {
        guard xpc_get_type(d) == XPC_TYPE_DICTIONARY, let s = xpc_dictionary_get_string(d, "kind") else { return nil }
        return FileToolsKind(rawValue: String(cString: s))
    }

    public static func payload<T: Decodable>(_ type: T.Type, _ d: xpc_object_t) -> T? {
        guard xpc_get_type(d) == XPC_TYPE_DICTIONARY else { return nil }
        var length = 0
        guard let p = xpc_dictionary_get_data(d, "payload", &length), length > 0 else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(bytes: p, count: length))
    }

    /// New descriptors for every "<prefix>.<i>" (−1 where one is missing); the caller closes them.
    public static func fds(_ d: xpc_object_t, prefix: String) -> [Int32] {
        let n = max(0, min(Int(xpc_dictionary_get_int64(d, "\(prefix).count")), 256))
        return (0..<n).map { xpc_dictionary_dup_fd(d, "\(prefix).\($0)") }
    }

    /// Short description of an XPC error object (connection interrupted / invalid).
    public static func errorDescription(_ o: xpc_object_t) -> String? {
        guard xpc_get_type(o) == XPC_TYPE_ERROR else { return nil }
        if let s = xpc_dictionary_get_string(o, XPC_ERROR_KEY_DESCRIPTION) { return String(cString: s) }
        return "xpc error"
    }
}
