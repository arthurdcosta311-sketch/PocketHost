//
//  HTTPMessage.swift
//  PocketHost
//
//  Minimal HTTP/1.1 request and response types used by the built-in server.
//

import Foundation

// MARK: - Request

struct HTTPRequest {
    let method: String
    let target: String
    let path: String
    let query: String?
    let version: String
    let headers: [String: String]

    init?(head: String) {
        let normalized = head.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        guard !method.isEmpty else { return nil }

        let target = String(parts[1])
        guard target.hasPrefix("/") || target.lowercased().hasPrefix("http") else { return nil }

        var path = target
        var query: String?

        if let questionMark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<questionMark])
            let remainder = String(target[target.index(after: questionMark)...])
            query = remainder.isEmpty ? nil : remainder
        }

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            parsedHeaders[key] = value
        }

        self.method = method
        self.target = target
        self.path = path.isEmpty ? "/" : path
        self.query = query
        self.version = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"
        self.headers = parsedHeaders
    }
}

// MARK: - Status

struct HTTPStatus: Equatable {
    let code: Int
    let reason: String

    var line: String { "HTTP/1.1 \(code) \(reason)" }

    static let ok = HTTPStatus(code: 200, reason: "OK")
    static let partialContent = HTTPStatus(code: 206, reason: "Partial Content")
    static let movedPermanently = HTTPStatus(code: 301, reason: "Moved Permanently")
    static let badRequest = HTTPStatus(code: 400, reason: "Bad Request")
    static let forbidden = HTTPStatus(code: 403, reason: "Forbidden")
    static let notFound = HTTPStatus(code: 404, reason: "Not Found")
    static let methodNotAllowed = HTTPStatus(code: 405, reason: "Method Not Allowed")
    static let requestTooLarge = HTTPStatus(code: 413, reason: "Content Too Large")
    static let rangeNotSatisfiable = HTTPStatus(code: 416, reason: "Range Not Satisfiable")
    static let internalServerError = HTTPStatus(code: 500, reason: "Internal Server Error")
}

// MARK: - Response

enum HTTPBody {
    case empty
    case data(Data)
    case file(FileHandle, UInt64)
}

struct HTTPResponse {
    var status: HTTPStatus
    var headers: [String: String]
    var body: HTTPBody

    init(status: HTTPStatus, headers: [String: String] = [:], body: HTTPBody = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    var contentLength: Int64 {
        Int64(headers["Content-Length"] ?? "0") ?? 0
    }

    func serializedHead(serverName: String) -> Data {
        var lines: [String] = [status.line]
        lines.append("Server: \(serverName)")
        lines.append("Connection: close")
        lines.append("Date: \(Self.httpDateFormatter.string(from: Date()))")
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
