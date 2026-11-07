//
//  NetworkInfo.swift
//  PocketHost
//
//  Finds the IPv4 address of the device so the app can show the URL other
//  machines on the Wi-Fi should open.
//

import Darwin
import Foundation

enum NetworkInfo {
    static func localIPv4Address() -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return nil }
        defer { freeifaddrs(interfacePointer) }

        var candidates: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first

        while let current = pointer {
            pointer = current.pointee.ifa_next

            let interface = current.pointee
            guard let address = interface.ifa_addr else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip") else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { continue }
            let value = String(cString: buffer)
            guard !value.isEmpty else { continue }

            if name == "en0" { return value }
            candidates.append(value)
        }

        return candidates.first
    }

    /// The IPv4 address and netmask of the interface traffic leaves through, so
    /// the router at the other end can be worked out.
    static func localIPv4Interface() -> (address: String, netmask: String)? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return nil }
        defer { freeifaddrs(interfacePointer) }

        var fallback: (address: String, netmask: String)?

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            pointer = current.pointee.ifa_next

            let interface = current.pointee
            guard let address = interface.ifa_addr, let mask = interface.ifa_netmask else { continue }
            guard address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip") else { continue }

            guard let ip = host(address), let netmask = host(mask) else { continue }

            if name == "en0" { return (ip, netmask) }
            if fallback == nil { fallback = (ip, netmask) }
        }

        return fallback
    }

    /// Addresses worth trying as the router's LAN side.
    static func gatewayCandidates() -> [String] {
        guard let interface = localIPv4Interface(),
              let address = ipv4Value(interface.address),
              let mask = ipv4Value(interface.netmask)
        else { return ["192.168.1.1", "10.0.0.1"] }

        let base = address & mask
        var values: [String] = []

        for candidate in [base &+ 1, base | 254] {
            let text = ipv4Text(candidate)
            if !values.contains(text) { values.append(text) }
        }

        if !values.contains("192.168.1.1") { values.append("192.168.1.1") }
        return values
    }

    /// A globally routable IPv6 address, if the network gave this device one.
    static func globalIPv6Address() -> String? {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else { return nil }
        defer { freeifaddrs(interfacePointer) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            pointer = current.pointee.ifa_next

            let interface = current.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("pdp_ip") else { continue }

            guard let value = host(address) else { continue }
            let prefix = value.lowercased().prefix(4)

            // Link-local feeds and unique-local ranges are not reachable from
            // the internet; neither is an IPv4-mapped address.
            if prefix.hasPrefix("fe8") || prefix.hasPrefix("fe9") ||
                prefix.hasPrefix("fea") || prefix.hasPrefix("feb") { continue }
            if prefix.hasPrefix("fc") || prefix.hasPrefix("fd") { continue }
            if value.lowercased().hasPrefix("::ffff:") { continue }

            return value
        }

        return nil
    }

    private static func host(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &buffer,
            socklen_t(buffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    private static func ipv4Value(_ text: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    private static func ipv4Text(_ value: UInt32) -> String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(cString: buffer)
    }

    // MARK: - Ports

    /// Whether a TCP port can be bound on this device right now. Used before
    /// starting the listener, so a port already taken by another app (or by a
    /// Mac service when running in the Simulator) is skipped instead of
    /// leaving the server offline with nothing to serve.
    static func isPortAvailable(_ port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = INADDR_ANY.bigEndian

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    /// Picks a usable port, starting at `start` and walking upwards.
    static func firstAvailablePort(startingAt start: Int, attempts: Int = 20) -> Int {
        let first = max(1024, min(start, 65535))

        for offset in 0..<max(1, attempts) {
            let candidate = first + offset
            if candidate > 65535 { break }
            if isPortAvailable(UInt16(candidate)) { return candidate }
        }

        return first
    }
}
