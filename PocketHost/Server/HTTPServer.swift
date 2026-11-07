//
//  HTTPServer.swift
//  PocketHost
//
//  A small HTTP/1.1 server built on Network.framework. It listens on every
//  interface, so the same folders are reachable at localhost on this device
//  and over Wi-Fi from anything else on the network.
//

import Foundation
import Network

// MARK: - Events

struct HTTPLogEntry: Identifiable, Equatable {
    let id: UUID
    let method: String
    let path: String
    let status: Int
    let bytes: Int64
    let date: Date
    let client: String
    let origin: RequestOrigin
    /// The answer told the client it may keep this copy on its own storage.
    let storesOnDevice: Bool

    init(
        method: String,
        path: String,
        status: Int,
        bytes: Int64,
        date: Date = Date(),
        client: String,
        origin: RequestOrigin = .remote,
        storesOnDevice: Bool = false
    ) {
        self.id = UUID()
        self.method = method
        self.path = path
        self.status = status
        self.bytes = bytes
        self.date = date
        self.client = client
        self.origin = origin
        self.storesOnDevice = storesOnDevice
    }
}

/// Who asked for the document: another machine on the network, or the
/// on-device runner keeping the runtime warm.
enum RequestOrigin: String {
    case remote
    case device
}

enum ServerEvent {
    case listening
    case stopped
    case failure(String)
    case request(HTTPLogEntry)
}

enum HTTPServerError: LocalizedError {
    case invalidPort
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "That port number is not available. Pick a value between 1024 and 65535."
        case .listenerFailed(let reason):
            return reason
        }
    }
}

// MARK: - Server

final class HTTPServer {
    struct Configuration {
        var root: URL
        var port: UInt16
        var servesDirectoryListings: Bool
        var allowsCORS: Bool
        var advertisesBonjour: Bool
        var displayName: String
        /// Let the device that fetched a file keep it in its own cache.
        var cachesOnDevice: Bool = true
    }

    private let queue = DispatchQueue(label: "com.pockethost.http", qos: .userInitiated)
    private var configuration: Configuration
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    var onEvent: ((ServerEvent) -> Void)?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func start(with configuration: Configuration) throws {
        stop()

        self.configuration = configuration

        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw HTTPServerError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw HTTPServerError.listenerFailed(error.localizedDescription)
        }

        if configuration.advertisesBonjour {
            listener.service = NWListener.Service(name: configuration.displayName, type: "_http._tcp")
        }

        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                if self.listener === listener { self.emit(.listening) }
            case .failed(let error):
                if self.listener === listener {
                    self.emit(.failure(error.localizedDescription))
                    listener.cancel()
                }
            case .cancelled:
                if self.listener === listener {
                    self.listener = nil
                    self.emit(.stopped)
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let handler = HTTPConnection(connection: connection, configuration: configuration, queue: queue)
        let key = ObjectIdentifier(handler)

        connections[key] = handler
        handler.onLog = { [weak self] entry in
            self?.emit(.request(entry))
        }
        handler.onClose = { [weak self] in
            self?.connections.removeValue(forKey: key)
        }
        handler.start()
    }

    private func emit(_ event: ServerEvent) {
        guard let onEvent else { return }
        DispatchQueue.main.async {
            onEvent(event)
        }
    }
}

// MARK: - One connection, one request

final class HTTPConnection {
    private let connection: NWConnection
    private let configuration: HTTPServer.Configuration
    private let responder: HTTPResponder
    private let queue: DispatchQueue
    private let client: String

    var onLog: ((HTTPLogEntry) -> Void)?
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var pendingRequest: HTTPRequest?
    private var expectedBody = 0
    private var requestBody = Data()
    private var pending: (request: HTTPRequest?, response: HTTPResponse)?
    private var finished = false
    private var didRespond = false

    init(connection: NWConnection, configuration: HTTPServer.Configuration, queue: DispatchQueue) {
        self.connection = connection
        self.configuration = configuration
        self.queue = queue
        self.responder = HTTPResponder(
            root: configuration.root,
            directoryListing: configuration.servesDirectoryListings,
            cors: configuration.allowsCORS,
            cachesOnDevice: configuration.cachesOnDevice
        )
        self.client = String(describing: connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)

                if self.buffer.count > 65_536 {
                    self.respond(
                        HTTPResponder.message(
                            .requestTooLarge,
                            title: "Request too large",
                            detail: "The request headers were larger than 64 KB."
                        ),
                        request: nil
                    )
                    return
                }

                if let separator = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headData = Data(self.buffer[self.buffer.startIndex..<separator.lowerBound])
                    let rest = Data(self.buffer[separator.upperBound...])
                    self.buffer = Data()
                    self.handleHead(headData, rest: rest)
                    return
                }
            }

            if error != nil {
                self.close()
                return
            }

            if isComplete {
                if self.buffer.isEmpty {
                    self.close()
                } else {
                    self.respond(
                        HTTPResponder.message(
                            .badRequest,
                            title: "Incomplete request",
                            detail: "The HTTP request ended before its headers were complete."
                        ),
                        request: nil
                    )
                }
                return
            }

            self.receive()
        }
    }

    private func handleHead(_ data: Data, rest: Data) {
        let head = String(decoding: data, as: UTF8.self)

        guard let request = HTTPRequest(head: head) else {
            respond(
                HTTPResponder.message(
                    .badRequest,
                    title: "Bad request",
                    detail: "PocketHost could not understand that HTTP request."
                ),
                request: nil
            )
            return
        }

        guard request.method == "POST" else {
            respond(responder.respond(to: request), request: request)
            return
        }

        // A POST carries a body: the crypto endpoint is the only one that takes
        // one, so anything else is answered without waiting for it.
        let declared = Int(request.headers["content-length"] ?? "0") ?? 0
        guard declared > 0 else {
            respond(responder.respond(to: request, body: Data()), request: request)
            return
        }

        guard declared <= WebCrypto.maximumBodyBytes else {
            respond(
                HTTPResponder.message(
                    .requestTooLarge,
                    title: "Request too large",
                    detail: "The crypto endpoint accepts up to \(WebCrypto.maximumBodyBytes / (1024 * 1024)) MB."
                ),
                request: request
            )
            return
        }

        pendingRequest = request
        expectedBody = declared
        requestBody = rest

        if requestBody.count >= expectedBody {
            completeRequest(request, body: requestBody)
        } else {
            receiveBody()
        }
    }

    private func receiveBody() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished, let request = self.pendingRequest else { return }

            if let data, !data.isEmpty {
                self.requestBody.append(data)

                if self.requestBody.count > self.expectedBody {
                    self.requestBody = Data(self.requestBody.prefix(self.expectedBody))
                }

                if self.requestBody.count >= self.expectedBody {
                    self.completeRequest(request, body: self.requestBody)
                    return
                }
            }

            if error != nil {
                self.close()
                return
            }

            if isComplete {
                self.respond(
                    HTTPResponder.message(
                        .badRequest,
                        title: "Incomplete request",
                        detail: "The request body ended before it was complete."
                    ),
                    request: nil
                )
                return
            }

            self.receiveBody()
        }
    }

    private func completeRequest(_ request: HTTPRequest, body: Data) {
        pendingRequest = nil
        requestBody = Data()
        expectedBody = 0
        respond(responder.respond(to: request, body: body), request: request)
    }

    // MARK: - Writing

    private func respond(_ response: HTTPResponse, request: HTTPRequest?) {
        guard !finished, !didRespond else { return }
        didRespond = true

        pending = (request, response)

        let head = response.serializedHead(serverName: configuration.displayName)
        let isHeadRequest = request?.method == "HEAD"

        switch response.body {
        case .empty:
            send(head) { self.finish() }

        case .data(let data):
            if isHeadRequest || data.isEmpty {
                send(head) { self.finish() }
            } else if data.count <= 512 * 1024 {
                // One write for the whole response: no extra round trip through
                // the queue, so small pages and assets land in a single pass.
                var payload = head
                payload.append(data)
                send(payload) { self.finish() }
            } else {
                send(head) {
                    self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil {
                            self.close()
                            return
                        }
                        self.finish()
                    })
                }
            }

        case .file(let handle, let length):
            if isHeadRequest {
                try? handle.close()
                send(head) { self.finish() }
                return
            }
            send(head) {
                self.stream(handle: handle, remaining: length)
            }
        }
    }

    private func send(_ data: Data, completion: @escaping () -> Void) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close()
                return
            }
            completion()
        })
    }

    private func stream(handle: FileHandle, remaining: UInt64) {
        guard !finished else {
            try? handle.close()
            return
        }

        if remaining == 0 {
            try? handle.close()
            finish()
            return
        }

        let chunkSize = Int(min(remaining, 262_144))
        let data = try? handle.read(upToCount: chunkSize)

        guard let data, !data.isEmpty else {
            try? handle.close()
            finish()
            return
        }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                self.close()
                return
            }
            self.stream(handle: handle, remaining: remaining - UInt64(data.count))
        })
    }

    private func finish() {
        guard let pending else {
            close()
            return
        }
        self.pending = nil

        if let request = pending.request {
            let origin: RequestOrigin = request.headers["x-pockethost-device-run"] != nil ? .device : .remote
            let control = pending.response.headers["Cache-Control"]?.lowercased() ?? ""
            let storesOnDevice = pending.response.status == .ok && control.contains("max-age=")
            onLog?(HTTPLogEntry(
                method: request.method,
                path: request.target,
                status: pending.response.status.code,
                bytes: pending.response.contentLength,
                client: client,
                origin: origin,
                storesOnDevice: storesOnDevice
            ))
        }

        close()
    }

    private func close() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }
}
