import Foundation

enum PocketWikiRouteBuilder {
    static func build(
        port: Int,
        bindHost: String,
        publicHosts: [String],
        addresses: [String] = localIPv4Addresses()
    ) -> PocketWikiRouteSnapshot {
        let lan = addresses.filter(isPrivateLAN).map { formatHTTPURL(host: $0, port: port) }
        let tailscale = addresses.filter(isTailscale).map { formatHTTPURL(host: $0, port: port) }
        let other = addresses
            .filter { !isPrivateLAN($0) && !isTailscale($0) }
            .map { formatHTTPURL(host: $0, port: port) }

        return PocketWikiRouteSnapshot(
            port: port,
            bindHost: bindHost,
            portless: port == 80,
            local: [formatHTTPURL(host: "localhost", port: port)],
            mdns: publicHosts.map { formatHTTPURL(host: $0, port: port) },
            lan: lan + other,
            tailscale: tailscale
        )
    }

    static func formatHTTPURL(host: String, port: Int) -> String {
        port == 80 ? "http://\(host)" : "http://\(host):\(port)"
    }

    static func parsePublicHosts(_ rawValue: String) -> [String] {
        let hosts = rawValue
            .split(separator: ",")
            .map { normalizeLocalHost(String($0)) }
            .filter { !$0.isEmpty }
        return Array(NSOrderedSet(array: hosts)) as? [String] ?? hosts
    }

    static func normalizeLocalHost(_ rawValue: String) -> String {
        let clean = rawValue
            .pocketTrimmed
            .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
        guard !clean.isEmpty else { return "" }
        return clean.hasSuffix(".local") ? clean : "\(clean).local"
    }

    static func isPrivateLAN(_ ip: String) -> Bool {
        let parts = ipv4Parts(ip)
        guard parts.count == 4 else { return false }
        return parts[0] == 10
            || parts[0] == 192 && parts[1] == 168
            || parts[0] == 172 && (16...31 ~= parts[1])
    }

    static func isTailscale(_ ip: String) -> Bool {
        let parts = ipv4Parts(ip)
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127 ~= parts[1])
    }

    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = host.withUnsafeBufferPointer { buffer in
                let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
                let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
            guard address != "127.0.0.1", !address.hasPrefix("169.254.") else { continue }
            addresses.append(address)
        }

        return addresses.sorted {
            if isPrivateLAN($0) != isPrivateLAN($1) {
                return isPrivateLAN($0)
            }
            return $0 < $1
        }
    }

    private static func ipv4Parts(_ ip: String) -> [Int] {
        let values = ip.split(separator: ".").compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ 0...255 ~= $0 }) else { return [] }
        return values
    }
}
