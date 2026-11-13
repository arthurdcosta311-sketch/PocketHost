//
//  DNSLookup.swift
//  PocketHost
//
//  Resolves a domain with the system resolver, so the app can say whether a
//  custom domain really reaches the deployment yet.
//

import Foundation

enum DNSLookup {
    /// Every IPv4 and IPv6 address the domain resolves to.
    static func addresses(for host: String) -> [String] {
        var output: [String] = []

        for family in [AF_INET, AF_INET6] {
            var hints = addrinfo()
            hints.ai_family = family
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { continue }
            defer { freeaddrinfo(first) }

            var pointer: UnsafeMutablePointer<addrinfo>? = first
            while let current = pointer {
                if let address = current.pointee.ai_addr {
                    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        address,
                        current.pointee.ai_addrlen,
                        &buffer,
                        socklen_t(buffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let text = String(cString: buffer)
                        if !text.isEmpty, !output.contains(text) {
                            output.append(text)
                        }
                    }
                }
                pointer = current.pointee.ai_next
            }
        }

        return output
    }

    /// The name the resolver ended up at when it differs from the one asked
    /// for — a CNAME target, in practice.
    static func canonicalName(for host: String) -> String? {
        var hints = addrinfo()
        hints.ai_flags = AI_CANONNAME
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        guard let name = first.pointee.ai_canonname else { return nil }
        let text = String(cString: name)
        guard !text.isEmpty, text.lowercased() != host.lowercased() else { return nil }
        return text
    }
}
