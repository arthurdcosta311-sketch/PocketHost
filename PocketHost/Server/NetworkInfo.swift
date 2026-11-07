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
