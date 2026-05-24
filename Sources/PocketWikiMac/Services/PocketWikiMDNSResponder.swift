import Darwin
import Foundation

final class PocketWikiMDNSResponder: NSObject, NetServiceDelegate {
    private var services: [NetService] = []
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "PocketWiki.MDNSResponder")
    private var aRecordHosts = Set<String>()
    private var aRecordAddress = ""
    private let log: @Sendable (PocketWikiServerLogEntry) -> Void

    init(log: @escaping @Sendable (PocketWikiServerLogEntry) -> Void) {
        self.log = log
    }

    func start(hosts: [String], port: Int) {
        stop()
        guard !hosts.isEmpty else { return }

        services = hosts.map { host in
            let service = NetService(domain: "local.", type: "_http._tcp.", name: "PocketWiki \(host)", port: Int32(port))
            service.includesPeerToPeer = true
            service.delegate = self
            service.publish()
            return service
        }

        startARecordResponder(hosts: hosts)
        log(PocketWikiServerLogEntry(level: .info, message: "mDNS anunciado para \(hosts.joined(separator: ", ")) em _http._tcp."))
    }

    func stop() {
        services.forEach { $0.stop() }
        services.removeAll()
        if let readSource {
            self.readSource = nil
            socketFD = -1
            readSource.cancel()
        } else if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        log(PocketWikiServerLogEntry(level: .warning, message: "mDNS falhou para \(sender.name): \(errorDict)"))
    }

    private func startARecordResponder(hosts: [String]) {
        guard let address = PocketWikiRouteBuilder.localIPv4Addresses().first else {
            log(PocketWikiServerLogEntry(level: .warning, message: "mDNS A record sem IPv4 LAN disponivel."))
            return
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            log(PocketWikiServerLogEntry(level: .warning, message: "mDNS socket falhou."))
            return
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddress = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(5353).bigEndian,
            sin_addr: in_addr(s_addr: INADDR_ANY),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )

        let bindResult = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            log(PocketWikiServerLogEntry(level: .warning, message: "mDNS bind :5353 falhou."))
            return
        }

        var multicast = ip_mreq()
        inet_pton(AF_INET, "224.0.0.251", &multicast.imr_multiaddr)
        multicast.imr_interface = in_addr(s_addr: INADDR_ANY)
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &multicast, socklen_t(MemoryLayout<ip_mreq>.size))

        socketFD = fd
        aRecordHosts = Set(hosts.map { normalizedDNSName($0) })
        aRecordAddress = address

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readPacket()
        }
        source.setCancelHandler {
            close(fd)
        }
        readSource = source
        source.resume()
        announceARecords()
    }

    private func readPacket() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1500)
        var sender = sockaddr_storage()
        var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = withUnsafeMutablePointer(to: &sender) { senderPointer in
            senderPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                recvfrom(socketFD, &buffer, buffer.count, 0, sockaddrPointer, &senderLength)
            }
        }
        guard count > 0 else { return }

        let packet = Array(buffer.prefix(Int(count)))
        let questions = DNSQuestion.parse(packet)
        let matchingNames = questions
            .filter { ($0.type == 1 || $0.type == 255) && aRecordHosts.contains(normalizedDNSName($0.name)) }
            .map(\.name)
        guard !matchingNames.isEmpty, let response = DNSResponseBuilder.aRecordResponse(query: packet, names: matchingNames, address: aRecordAddress) else {
            return
        }

        send(response)
    }

    private func announceARecords() {
        guard let response = DNSResponseBuilder.aRecordAnnouncement(names: Array(aRecordHosts), address: aRecordAddress) else { return }
        send(response)
    }

    private func send(_ packet: [UInt8]) {
        guard socketFD >= 0 else { return }
        var target = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: in_port_t(5353).bigEndian,
            sin_addr: ipv4Address("224.0.0.251"),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        packet.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func ipv4Address(_ rawValue: String) -> in_addr {
        var address = in_addr()
        inet_pton(AF_INET, rawValue, &address)
        return address
    }

    private func normalizedDNSName(_ rawValue: String) -> String {
        let clean = rawValue.pocketTrimmed.lowercased()
        return clean.hasSuffix(".") ? String(clean.dropLast()) : clean
    }
}

private struct DNSQuestion {
    let name: String
    let type: UInt16

    static func parse(_ packet: [UInt8]) -> [DNSQuestion] {
        guard packet.count >= 12 else { return [] }
        let count = Int(readUInt16(packet, 4))
        var offset = 12
        var questions: [DNSQuestion] = []

        for _ in 0..<count {
            guard let name = readName(packet, offset: &offset), offset + 4 <= packet.count else { break }
            let type = readUInt16(packet, offset)
            offset += 4
            questions.append(DNSQuestion(name: name, type: type))
        }

        return questions
    }

    private static func readName(_ packet: [UInt8], offset: inout Int) -> String? {
        var labels: [String] = []
        while offset < packet.count {
            let length = Int(packet[offset])
            offset += 1
            if length == 0 { return labels.joined(separator: ".") }
            guard length < 64, offset + length <= packet.count else { return nil }
            let label = String(decoding: packet[offset..<(offset + length)], as: UTF8.self)
            labels.append(label)
            offset += length
        }
        return nil
    }
}

private enum DNSResponseBuilder {
    static func aRecordResponse(query: [UInt8], names: [String], address: String) -> [UInt8]? {
        guard query.count >= 2 else { return nil }
        return build(id: readUInt16(query, 0), names: names, address: address)
    }

    static func aRecordAnnouncement(names: [String], address: String) -> [UInt8]? {
        build(id: 0, names: names, address: address)
    }

    private static func build(id: UInt16, names: [String], address: String) -> [UInt8]? {
        guard let ip = ipv4Bytes(address), !names.isEmpty else { return nil }
        var packet: [UInt8] = []
        writeUInt16(id, to: &packet)
        writeUInt16(0x8400, to: &packet)
        writeUInt16(0, to: &packet)
        writeUInt16(UInt16(names.count), to: &packet)
        writeUInt16(0, to: &packet)
        writeUInt16(0, to: &packet)

        for name in names {
            writeName(name, to: &packet)
            writeUInt16(1, to: &packet)
            writeUInt16(0x8001, to: &packet)
            writeUInt32(120, to: &packet)
            writeUInt16(4, to: &packet)
            packet.append(contentsOf: ip)
        }

        return packet
    }

    private static func ipv4Bytes(_ address: String) -> [UInt8]? {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 ? parts : nil
    }

    private static func writeName(_ name: String, to packet: inout [UInt8]) {
        for label in name.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0)
    }
}

private func readUInt16(_ packet: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 1 < packet.count else { return 0 }
    return UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
}

private func writeUInt16(_ value: UInt16, to packet: inout [UInt8]) {
    packet.append(UInt8((value >> 8) & 0xff))
    packet.append(UInt8(value & 0xff))
}

private func writeUInt32(_ value: UInt32, to packet: inout [UInt8]) {
    packet.append(UInt8((value >> 24) & 0xff))
    packet.append(UInt8((value >> 16) & 0xff))
    packet.append(UInt8((value >> 8) & 0xff))
    packet.append(UInt8(value & 0xff))
}
