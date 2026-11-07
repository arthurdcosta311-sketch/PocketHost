//
//  GlobalAccess.swift
//  PocketHost
//
//  Makes the server reachable from outside the local network. The app asks the
//  router for a TCP port mapping (NAT-PMP first, then UPnP IGD) and, when no
//  router will open one, falls back to the device's global IPv6 address.
//

import Darwin
import Foundation

final class GlobalAccess {
    enum State: Equatable {
        case off
        case searching
        case available(url: String, method: String)
        case unavailable(String)
    }

    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "com.pockethost.global", qos: .utility)
    private var port: UInt16 = 0
    private var timer: DispatchSourceTimer?
    private var mapping: Mapping?

    private struct Mapping {
        let gateway: String?
        let upnp: UPnP.Device?
        let externalPort: UInt16
    }

    private(set) var state: State = .off

    // MARK: - Control

    func start(port: UInt16) {
        queue.async { [weak self] in
            guard let self else { return }
            self.clearMapping()
            self.port = port
            self.publish(.searching)
            self.activate()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.clearMapping()
            self.publish(.off)
        }
    }

    // MARK: - Work

    private func activate() {
        let lan = NetworkInfo.localIPv4Address()
        var sawPrivateAddress: String?

        if let lan {
            for candidate in NetworkInfo.gatewayCandidates() {
                guard let external = NATPMP.externalAddress(gateway: candidate),
                      let result = NATPMP.map(gateway: candidate, internalPort: port, externalPort: port)
                else { continue }

                if Self.isPublicIPv4(external) {
                    mapping = Mapping(gateway: candidate, upnp: nil, externalPort: result.externalPort)
                    finish(url: "http://\(external):\(result.externalPort)/", method: "NAT-PMP")
                    return
                }

                // The router answered, but its own outside address is private:
                // drop the mapping again and keep looking.
                _ = NATPMP.map(gateway: candidate, internalPort: port, externalPort: result.externalPort, lifetime: 0)
                sawPrivateAddress = external
            }

            for device in UPnP.devices() {
                guard let external = device.externalAddress(),
                      let externalPort = device.addMapping(internalPort: port, internalIP: lan)
                else { continue }

                if Self.isPublicIPv4(external) {
                    mapping = Mapping(gateway: nil, upnp: device, externalPort: externalPort)
                    finish(url: "http://\(external):\(externalPort)/", method: "UPnP")
                    return
                }

                device.delete(externalPort: externalPort)
                sawPrivateAddress = external
            }
        }

        clearMapping()

        if let address = NetworkInfo.globalIPv6Address() {
            finish(url: "http://[\(address)]:\(port)/", method: "IPv6", renew: false)
            return
        }

        if let sawPrivateAddress {
            publish(.unavailable("The router reports \(sawPrivateAddress) as its outside address, so your provider puts it behind another one and no port can be opened. An IPv6 address would not have that problem."))
            return
        }

        publish(.unavailable("No router on this network accepted a port mapping, and this device has no global IPv6 address."))
    }

    private func finish(url: String, method: String, renew: Bool = true) {
        publish(.available(url: url, method: method))
        if renew { scheduleRenewal() }
    }

    private func clearMapping() {
        timer?.cancel()
        timer = nil

        guard let mapping else { return }
        self.mapping = nil

        if let device = mapping.upnp {
            device.delete(externalPort: mapping.externalPort)
        } else if let gateway = mapping.gateway {
            _ = NATPMP.map(gateway: gateway, internalPort: port, externalPort: mapping.externalPort, lifetime: 0)
        }
    }

    private func scheduleRenewal() {
        timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1_200, repeating: 1_200)
        timer.setEventHandler { [weak self] in
            self?.renew()
        }
        timer.resume()
        self.timer = timer
    }

    /// Routers forget mappings; asking again well before the lease ends keeps
    /// the site reachable without the user doing anything.
    private func renew() {
        guard let mapping else { return }

        if let device = mapping.upnp {
            _ = device.addMapping(
                internalPort: port,
                internalIP: NetworkInfo.localIPv4Address() ?? "",
                externalPort: mapping.externalPort
            )
        } else if let gateway = mapping.gateway {
            _ = NATPMP.map(gateway: gateway, internalPort: port, externalPort: mapping.externalPort)
        }
    }

    private func publish(_ state: State) {
        self.state = state
        let callback = onStateChange
        DispatchQueue.main.async { callback?(state) }
    }

    // MARK: - Addresses

    static func isPublicIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }

        switch parts[0] {
        case 10, 127, 0: return false
        case 172 where (16...31).contains(parts[1]): return false
        case 192 where parts[1] == 168: return false
        case 169 where parts[1] == 254: return false
        case 100 where (64...127).contains(parts[1]): return false
        default: return true
        }
    }
}

// MARK: - NAT-PMP

fileprivate enum NATPMP {
    static let port: UInt16 = 5351

    /// The address the router sees the internet from.
    static func externalAddress(gateway: String) -> String? {
        guard let response = UDP.send(host: gateway, port: port, payload: Data([0, 0])),
              response.count >= 12
        else { return nil }

        guard resultCode(response) == 0 else { return nil }
        return "\(response[8]).\(response[9]).\(response[10]).\(response[11])"
    }

    /// Maps the port on the router and returns where it landed. A lifetime of
    /// zero removes an existing mapping.
    static func map(
        gateway: String,
        internalPort: UInt16,
        externalPort: UInt16,
        lifetime: UInt32 = 3_600
    ) -> (externalPort: UInt16, lifetime: UInt32)? {
        var request = Data([0, 2, 0, 0])
        withUnsafeBytes(of: internalPort.bigEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: externalPort.bigEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: lifetime.bigEndian) { request.append(contentsOf: $0) }

        guard let response = UDP.send(host: gateway, port: port, payload: request),
              response.count >= 16
        else { return nil }

        guard resultCode(response) == 0 else { return nil }

        let mapped = (UInt16(response[10]) << 8) | UInt16(response[11])
        let life = (UInt32(response[12]) << 24) | (UInt32(response[13]) << 16) |
                   (UInt32(response[14]) << 8) | UInt32(response[15])

        return (mapped, life)
    }

    private static func resultCode(_ response: Data) -> UInt16 {
        (UInt16(response[2]) << 8) | UInt16(response[3])
    }
}

// MARK: - UPnP

fileprivate enum UPnP {
    struct Device {
        let controlURL: URL
        let serviceType: String

        func externalAddress() -> String? {
            let action = "GetExternalIPAddress"
            let body = "<u:\(action) xmlns:u=\"\(serviceType)\"></u:\(action)>"

            guard let data = soap(action: action, body: body),
                  let text = String(data: data, encoding: .utf8),
                  let value = UPnP.tag("NewExternalIPAddress", in: text),
                  !value.isEmpty
            else { return nil }

            return value
        }

        /// Asks the router to forward the port to this phone.
        func addMapping(
            internalPort: UInt16,
            internalIP: String,
            externalPort: UInt16 = 0,
            lifetime: UInt32 = 3_600
        ) -> UInt16? {
            let port = externalPort == 0 ? internalPort : externalPort
            let action = "AddPortMapping"
            let body = """
            <u:\(action) xmlns:u="\(serviceType)"><NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>TCP</NewProtocol><NewInternalPort>\(internalPort)</NewInternalPort><NewInternalClient>\(internalIP)</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>PocketHost</NewPortMappingDescription><NewLeaseDuration>\(lifetime)</NewLeaseDuration></u:\(action)>
            """

            guard let data = soap(action: action, body: body),
                  let text = String(data: data, encoding: .utf8),
                  let value = UPnP.tag("NewExternalPort", in: text),
                  let mapped = UInt16(value)
            else { return nil }

            return mapped
        }

        func delete(externalPort: UInt16) {
            let action = "DeletePortMapping"
            let body = """
            <u:\(action) xmlns:u="\(serviceType)"><NewRemoteHost></NewRemoteHost><NewExternalPort>\(externalPort)</NewExternalPort><NewProtocol>TCP</NewProtocol></u:\(action)>
            """
            _ = soap(action: action, body: body)
        }

        private func soap(action: String, body: String) -> Data? {
            let envelope = """
            <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
            """

            var request = URLRequest(url: controlURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 6
            request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
            request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
            request.httpBody = envelope.data(using: .utf8)

            return UPnP.fetch(request)
        }
    }

    /// Finds the gateway device's port-mapping services on the network.
    static func devices() -> [Device] {
        let request = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        \r

        """.data(using: .utf8) ?? Data()

        let responses = UDP.send(host: "239.255.255.250", port: 1_900, payload: request, timeout: 2, replies: 12)

        var devices: [Device] = []
        var seen: Set<String> = []

        for response in responses {
            guard let text = String(data: response, encoding: .utf8),
                  let location = header("location", in: text),
                  let url = URL(string: location),
                  seen.insert(location).inserted
            else { continue }

            guard let description = fetch(URLRequest(url: url), timeout: 5),
                  let xml = String(data: description, encoding: .utf8)
            else { continue }

            devices.append(contentsOf: services(in: xml, base: url))
        }

        return devices
    }

    // MARK: - Parsing

    private static func services(in xml: String, base: URL) -> [Device] {
        guard let regex = try? NSRegularExpression(
            pattern: "<service>(.*?)</service>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }

        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        var devices: [Device] = []

        for match in regex.matches(in: xml, options: [], range: range) {
            guard match.numberOfRanges > 1,
                  let block = Range(match.range(at: 1), in: xml)
            else { continue }

            let body = String(xml[block])
            guard let type = tag("serviceType", in: body) else { continue }
            guard type.contains("WANIPConnection") || type.contains("WANPPPConnection") else { continue }
            guard let path = tag("controlURL", in: body) else { continue }
            guard let controlURL = URL(string: path, relativeTo: base)?.absoluteURL else { continue }

            devices.append(Device(controlURL: controlURL, serviceType: type))
        }

        return devices
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "<\(name)[^>]*>(.*?)</\(name)>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let value = Range(match.range(at: 1), in: text)
        else { return nil }

        return String(text[value]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func header(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: - Requests

    private static func fetch(_ request: URLRequest, timeout: TimeInterval = 6) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Data?

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            output = data
            semaphore.signal()
        }
        task.resume()

        _ = semaphore.wait(timeout: .now() + timeout)
        task.cancel()
        return output
    }
}

// MARK: - UDP

fileprivate enum UDP {
    static func send(host: String, port: UInt16, payload: Data, timeout: TimeInterval = 1.2) -> Data? {
        send(host: host, port: port, payload: payload, timeout: timeout, replies: 1).first
    }

    static func send(host: String, port: UInt16, payload: Data, timeout: TimeInterval, replies: Int) -> [Data] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return [] }

        let sent = payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(
                        descriptor,
                        bytes.baseAddress,
                        bytes.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sent == payload.count else { return [] }

        var wait = timeval(tv_sec: 0, tv_usec: suseconds_t(timeout * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var results: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 2_048)

        while results.count < max(1, replies) {
            let received = recv(descriptor, &buffer, buffer.count, 0)
            guard received > 0 else { break }
            results.append(Data(buffer.prefix(received)))
        }

        return results
    }
}
