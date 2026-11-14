// M7.T02 step 1 (R-249, NFR-SEC5; P-files-tools-10, Open WebUI `_assert_addresses_allowed` precedent): a page URL
// may be fetched only when it is http(s) and every address its host resolves to is public. Refused: loopback,
// link-local, RFC 1918, CGNAT 100.64/10, this-network 0/8, multicast/reserved, ULA fc00::/7, IPv6 link-local and
// site-local, IPv4-mapped / IPv4-compatible / NAT64 / 6to4 addresses embedding a refused IPv4, and every scheme but
// http/https (`file:`, `data:` …). PageFetcher re-checks every redirect (≤ 5) and the address the connection used
// (URLSessionTaskMetrics), so a DNS answer that changes between the check and the connect (rebinding) is caught.
import Darwin
import Foundation

public struct SSRFGuard: Sendable {
    public enum Refusal: Error, Equatable, Sendable {
        case scheme(String), noHost, unresolvable(String), privateAddress(String), tooManyRedirects
    }

    /// Host → addresses (numeric strings). Injectable for tests (rebinding, fixed answers).
    public typealias Resolver = @Sendable (String) -> [String]
    public let resolve: Resolver
    public static let maxRedirects = 5

    public init(resolve: @escaping Resolver = SSRFGuard.systemResolve) { self.resolve = resolve }

    /// Throws `Refusal` unless `url` may be fetched. Returns the addresses it checked.
    @discardableResult
    public func check(_ url: URL) throws -> [String] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Refusal.scheme(url.scheme ?? "")
        }
        guard var host = url.host(percentEncoded: false), !host.isEmpty else { throw Refusal.noHost }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let addrs = Self.isLiteral(host) ? [host] : resolve(host)
        guard !addrs.isEmpty else { throw Refusal.unresolvable(host) }
        for a in addrs where !Self.isPublic(a) { throw Refusal.privateAddress(a) }
        return addrs
    }

    public static func isLiteral(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }

    public static let systemResolve: Resolver = { host in
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = ai.pointee.ai_next
        }
        return Array(Set(out)).sorted()
    }

    /// True for a globally routable unicast address.
    public static func isPublic(_ address: String) -> Bool {
        var s = address
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }  // zone id (fe80::1%en0)
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 { return isPublicV4(UInt32(bigEndian: v4.s_addr)) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, s, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        return isPublicV6(b)
    }

    static func isPublicV4(_ a: UInt32) -> Bool {
        func inNet(_ net: UInt32, _ bits: UInt32) -> Bool { bits == 0 ? true : (a >> (32 - bits)) == (net >> (32 - bits)) }
        let refused: [(UInt32, UInt32)] = [
            (0x0000_0000, 8),   // 0.0.0.0/8 this network
            (0x0A00_0000, 8),   // 10/8
            (0x6440_0000, 10),  // 100.64/10 CGNAT
            (0x7F00_0000, 8),   // 127/8 loopback
            (0xA9FE_0000, 16),  // 169.254/16 link-local (cloud metadata)
            (0xAC10_0000, 12),  // 172.16/12
            (0xC000_0000, 24),  // 192.0.0/24 IETF protocol assignments
            (0xC000_0200, 24),  // 192.0.2/24 TEST-NET-1
            (0xC0A8_0000, 16),  // 192.168/16
            (0xC612_0000, 15),  // 198.18/15 benchmarking
            (0xC633_6400, 24),  // 198.51.100/24 TEST-NET-2
            (0xCB00_7100, 24),  // 203.0.113/24 TEST-NET-3
            (0xE000_0000, 4),   // 224/4 multicast
            (0xF000_0000, 4),   // 240/4 reserved + broadcast
        ]
        return !refused.contains { inNet($0.0, $0.1) }
    }

    static func isPublicV6(_ b: [UInt8]) -> Bool {
        let zero10 = b[0..<10].allSatisfy { $0 == 0 }
        // ::, ::1
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return false }
        func v4(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        if zero10 && b[10] == 0xFF && b[11] == 0xFF { return isPublicV4(v4(12)) }                 // ::ffff:a.b.c.d mapped
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPublicV4(v4(12)) }                         // ::a.b.c.d compatible
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B { return isPublicV4(v4(12)) }  // 64:ff9b::/96 NAT64
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicV4(v4(2)) }                               // 2002::/16 6to4
        if b[0] & 0xFE == 0xFC { return false }                                                    // fc00::/7 ULA
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }                                    // fe80::/10 link-local
        if b[0] == 0xFE && b[1] & 0xC0 == 0xC0 { return false }                                    // fec0::/10 site-local
        if b[0] == 0xFF { return false }                                                           // ff00::/8 multicast
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8 { return false }           // 2001:db8::/32 docs
        if b[0] == 0x01 && b[1..<8].allSatisfy({ $0 == 0 }) { return false }                       // 100::/64 discard
        return true
    }
}
