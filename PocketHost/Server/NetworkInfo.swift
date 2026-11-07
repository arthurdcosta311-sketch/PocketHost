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
}
