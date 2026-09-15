import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether the server we are talking to is on this device's own network.
///
/// This is the question Synology Photos' `Auto` actually asks — the original
/// file on a local network, the smaller rendition when remote — and it is a far
/// better one than "is this connection metered". Metered was a guess at the same
/// thing and it guessed wrong: a wi-fi network away from home reported itself
/// unmetered, so `Auto` handed it a 51 Mbps file over a link with barely twice
/// the headroom, and it stuttered.
///
/// Answered from the address actually reached rather than from the interface
/// type, because the interface cannot tell you where the other end *is*. Home
/// here is a global IPv6 address that happens to share a prefix with the phone's
/// own — not a private address at all — so "is it a 192.168 address" would miss
/// it entirely.
@MainActor
@Observable
final class NetworkLocality {
    static let shared = NetworkLocality()

    /// Nil until the first request completes. Treated as *not* local by
    /// `PlaybackSettings`: before there is evidence, the smaller stream is the
    /// safer guess — it plays everywhere, where the original does not.
    private(set) var isLocal: Bool?

    /// Called from the connection metrics as each request finishes.
    func noteServerAddress(_ address: String) {
        let local = AddressLocality.isLocal(address)
        guard local != isLocal else { return }
        isLocal = local
        Diagnostics.shared.log(
            .network, "Server reached on a \(local ? "local" : "remote") network"
        )
    }
}

/// Decides whether an address is on one of this device's own networks.
enum AddressLocality {
    static func isLocal(_ address: String) -> Bool {
        // A scope id ("fe80::1%en0") is not part of the address.
        let host = address.split(separator: "%").first.map(String.init) ?? address
        if host.contains(":") { return isOnOurIPv6Link(host) }
        return isPrivateIPv4(host)
    }

    /// Shares a /64 with one of our own addresses.
    ///
    /// Compared as bytes rather than as text: IPv6 may be written many ways for
    /// the same address, and `2600:4040:2e7e:2000::` versus
    /// `2600:4040:2e7e:2000:0:0:0:0` would not match as strings.
    private static func isOnOurIPv6Link(_ host: String) -> Bool {
        guard let theirs = ipv6Bytes(host) else { return false }
        return ourIPv6Prefixes().contains { $0 == Array(theirs.prefix(8)) }
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        // Link-local. Not a useful path, but it is certainly not remote.
        case (169, 254): return true
        default: return false
        }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, host, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    /// The /64 prefixes of every global IPv6 address this device holds.
    ///
    /// Link-local (`fe80::`) is skipped: everything shares that prefix, so
    /// including it would call every address on earth local.
    private static func ourIPv6Prefixes() -> [[UInt8]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var prefixes: [[UInt8]] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = interface.pointee.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let bytes = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count == 16 else { continue }
            // fe80::/10 — link-local, and useless as a discriminator.
            if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { continue }
            let prefix = Array(bytes.prefix(8))
            if !prefixes.contains(prefix) { prefixes.append(prefix) }
        }
        return prefixes
    }
}
