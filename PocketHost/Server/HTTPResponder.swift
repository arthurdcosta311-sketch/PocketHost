//
//  HTTPResponder.swift
//  PocketHost
//
//  Turns an HTTP request into a response: files, folder listings, redirects
//  and errors, with byte-range support for media.
//

import Foundation

struct HTTPResponder {
    let root: URL
    let directoryListing: Bool
    let cors: Bool

    private enum RangeResult {
        case satisfiable(Int64, Int64)
        case unsatisfiable
    }

    // MARK: - Dispatch

    func respond(to request: HTTPRequest) -> HTTPResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            var response = Self.message(
                .methodNotAllowed,
                title: "Method not allowed",
                detail: "PocketHost only answers GET and HEAD requests."
            )
            response.headers["Allow"] = "GET, HEAD"
            return response
        }

        guard let decoded = request.target.removingPercentEncoding,
              !decoded.contains("\0"),
              decoded.count < 4096
        else {
            return Self.message(
                .badRequest,
                title: "Bad request",
                detail: "The requested path could not be decoded."
            )
        }

        let pathOnly = decoded.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? "/"
        let path = pathOnly.hasPrefix("/") ? pathOnly : "/" + pathOnly
        let relative = String(path.dropFirst())
        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(relative.isEmpty ? "." : relative).standardizedFileURL
        let rootPath = rootURL.path

        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
            return Self.message(
                .forbidden,
                title: "Outside the hosted folder",
                detail: "That path points outside the folder PocketHost is serving."
            )
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return Self.message(
                .notFound,
                title: "Not found",
                detail: "There is no file at \(path) in the hosted folder."
            )
        }

        if isDirectory.boolValue {
            if !path.hasSuffix("/") {
                var location = path + "/"
                if let query = request.query { location += "?" + query }
                return HTTPResponse(
                    status: .movedPermanently,
                    headers: ["Location": location, "Content-Length": "0"],
                    body: .empty
                )
            }

            for indexName in ["index.html", "index.htm", "index.xhtml"] {
                let indexURL = candidate.appendingPathComponent(indexName)
                if FileManager.default.fileExists(atPath: indexURL.path) {
                    return fileResponse(at: indexURL, request: request)
                }
            }

            guard directoryListing else {
                return Self.message(
                    .forbidden,
                    title: "No index page",
                    detail: "This folder has no index.html and directory listings are turned off in Settings."
                )
            }

            return listingResponse(at: candidate, path: path, method: request.method)
        }

        return fileResponse(at: candidate, request: request)
    }

    // MARK: - Files

    private func fileResponse(at url: URL, request: HTTPRequest) -> HTTPResponse {
        let mimeType = MIMEType.type(forExtension: url.pathExtension)

        var headers: [String: String] = [
            "Content-Type": mimeType,
            "Cache-Control": "no-store",
            "Accept-Ranges": "bytes"
        ]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }

        let total = Self.fileSize(at: url)
        var status = HTTPStatus.ok
        var offset: Int64 = 0
        var length = total

        if let rangeHeader = request.headers["range"] {
            switch Self.parseRange(rangeHeader, total: total) {
            case .satisfiable(let start, let end):
                offset = start
                length = end - start + 1
                status = .partialContent
                headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
            case .unsatisfiable:
                headers["Content-Range"] = "bytes */\(total)"
                headers["Content-Length"] = "0"
                return HTTPResponse(status: .rangeNotSatisfiable, headers: headers, body: .empty)
            case .none:
                break
            }
        }

        headers["Content-Length"] = String(length)

        guard request.method != "HEAD" else {
            return HTTPResponse(status: status, headers: headers, body: .empty)
        }

        guard length > 0 else {
            return HTTPResponse(status: status, headers: headers, body: .data(Data()))
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Self.message(
                .internalServerError,
                title: "Could not read the file",
                detail: "PocketHost found \(url.lastPathComponent) but could not open it."
            )
        }

        if offset > 0 {
            do {
                try handle.seek(toOffset: UInt64(offset))
            } catch {
                try? handle.close()
                return Self.message(
                    .internalServerError,
                    title: "Could not read the file",
                    detail: "Seeking inside \(url.lastPathComponent) failed."
                )
            }
        }

        return HTTPResponse(status: status, headers: headers, body: .file(handle, UInt64(length)))
    }

    // MARK: - Listing

    private func listingResponse(at directory: URL, path: String, method: String) -> HTTPResponse {
        var entries: [ServerPages.ListingEntry] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                let name = url.lastPathComponent
                if name.hasPrefix(".") { continue }
                let values = try? url.resourceValues(forKeys: keys)
                entries.append(
                    ServerPages.ListingEntry(
                        name: name,
                        isDirectory: values?.isDirectory ?? false,
                        size: Int64(values?.fileSize ?? 0),
                        modified: values?.contentModificationDate
                    )
                )
            }
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let html = ServerPages.listingHTML(path: path, entries: entries)
        var headers: [String: String] = [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Length": String(html.utf8.count)
        ]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }

        return HTTPResponse(
            status: .ok,
            headers: headers,
            body: method == "HEAD" ? .empty : .data(Data(html.utf8))
        )
    }

    // MARK: - Errors

    static func message(_ status: HTTPStatus, title: String, detail: String) -> HTTPResponse {
        let html = ServerPages.messageHTML(statusCode: status.code, title: title, detail: detail)
        return HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "Content-Length": String(html.utf8.count)
            ],
            body: .data(Data(html.utf8))
        )
    }

    // MARK: - Ranges

    private static func parseRange(_ header: String, total: Int64) -> RangeResult? {
        guard header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }

        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let startText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(parts[1]).trimmingCharacters(in: .whitespaces)

        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0, total > 0 else { return .unsatisfiable }
            return .satisfiable(max(0, total - suffix), total - 1)
        }

        guard let start = Int64(startText) else { return nil }
        guard start < total else { return .unsatisfiable }

        if endText.isEmpty { return .satisfiable(start, total - 1) }
        guard let end = Int64(endText) else { return nil }
        guard end >= start else { return .unsatisfiable }

        return .satisfiable(start, min(end, total - 1))
    }

    // MARK: - Helpers

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
