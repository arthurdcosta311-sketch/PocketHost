//
//  StreamAPI.swift
//  PocketHost
//
//  The small API a source-driven site (dango and its like) needs from a server:
//  a health probe, a stream proxy that sends the Referer a CDN expects and
//  rewrites HLS playlists through itself, an AniLibria bridge, and an honest
//  answer where a Node provider engine would have been.
//

import Foundation

enum StreamAPI {
    static let healthPath = "/api/health"
    static let proxyPath = "/api/proxy"
    static let anilibriaPath = "/api/anilibria"
    static let providerPath = "/api/provider"

    private static let anilibriaAPI = "https://anilibria.top/api/v1"
    private static let timeout: TimeInterval = 20

    private static let anilibriaLock = NSLock()
    private static var anilibriaCache: [String: (at: Date, value: Any)] = [:]

    // MARK: - Routing

    static func handle(_ request: HTTPRequest, cors: Bool) -> HTTPResponse? {
        guard request.path.hasPrefix("/api/") else { return nil }

        switch request.path {
        case healthPath:
            return json(.ok, [
                "ok": true,
                "app": "dango",
                "proxy": true,
                "providers": false,
                "providerIds": [],
                "runtime": "pockethost"
            ], cors: cors)

        case proxyPath:
            return proxy(request, cors: cors)

        case anilibriaPath:
            return anilibria(request, cors: cors)

        case providerPath:
            return json(.serviceUnavailable, [
                "error": "The provider engine is not available on PocketHost, so this source cannot be resolved here. AniLibria and your own template sources still work."
            ], cors: cors)

        default:
            return json(.notFound, ["error": "No such API on this server."], cors: cors)
        }
    }

    // MARK: - Proxy

    private static func proxy(_ request: HTTPRequest, cors: Bool) -> HTTPResponse {
        guard let raw = query("url", in: request),
              let target = URL(string: raw),
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = target.host,
              !isPrivateHost(host)
        else {
            return json(.badRequest, ["error": "A public http(s) url is required."], cors: cors)
        }

        var upstream = URLRequest(url: target)
        upstream.timeoutInterval = timeout
        upstream.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        upstream.setValue(request.headers["accept"] ?? "*/*", forHTTPHeaderField: "Accept")
        if let range = request.headers["range"] {
            upstream.setValue(range, forHTTPHeaderField: "Range")
        }

        let referer = query("ref", in: request)
        if let referer {
            upstream.setValue(referer, forHTTPHeaderField: "Referer")
            if let url = URL(string: referer), let scheme = url.scheme, let host = url.host {
                upstream.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }

        let path = target.path.lowercased()
        let looksPlaylist = path.hasSuffix(".m3u8") || path.hasSuffix(".m3u")
        let looksSubtitle = [".srt", ".vtt", ".ass", ".ssa"].contains { path.hasSuffix($0) }

        if looksPlaylist || looksSubtitle {
            let result = fetch(upstream)
            guard let data = result.data else {
                return json(.badGateway, ["error": result.error ?? "The stream server did not answer."], cors: cors)
            }

            let response = result.response
            let text = String(data: data, encoding: .utf8) ?? ""
            let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let ok = (200..<300).contains(response.statusCode)
            let isPlaylist = looksPlaylist || type.contains("mpegurl")

            if isPlaylist {
                let body = ok ? rewritePlaylist(text, base: target, referer: referer) : text
                return textResponse(body, type: "application/vnd.apple.mpegurl", status: response.statusCode, cors: cors)
            }

            let body = ok ? toVTT(text) : text
            return textResponse(body, type: "text/vtt; charset=utf-8", status: response.statusCode, cors: cors)
        }

        let result = download(upstream)
        guard let file = result.file else {
            return json(.badGateway, ["error": result.error ?? "The stream server did not answer."], cors: cors)
        }

        let response = result.response

        let length = Int64((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0)

        var headers: [String: String] = [
            "Content-Type": response.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
            "Cache-Control": "no-store",
            "Accept-Ranges": "bytes"
        ]

        for (source, destination) in [
            ("content-range", "Content-Range"),
            ("accept-ranges", "Accept-Ranges"),
            ("etag", "ETag"),
            ("last-modified", "Last-Modified")
        ] {
            if let value = response.value(forHTTPHeaderField: source) {
                headers[destination] = value
            }
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return json(.badGateway, ["error": "The stream could not be read back."], cors: cors)
        }

        headers["Content-Length"] = String(length)
        let status = response.statusCode == 206 ? HTTPStatus.partialContent : HTTPStatus.ok

        // The temporary copy lives long enough for a slow stream to finish, and
        // is then cleaned up rather than left on the phone.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3_600) {
            try? FileManager.default.removeItem(at: file)
        }

        return HTTPResponse(
            status: status,
            headers: headers,
            body: request.method == "HEAD" ? .empty : .file(handle, UInt64(length))
        )
    }

    // MARK: - AniLibria

    private static func anilibria(_ request: HTTPRequest, cors: Bool) -> HTTPResponse {
        guard let title = query("title", in: request), !title.isEmpty else {
            return json(.badRequest, ["error": "title is required"], cors: cors)
        }

        let episode = max(1, Int(query("ep", in: request) ?? "") ?? 1)

        guard let search = anilibriaJSON("/anime/catalog/releases?f[search]=\(encodedQuery(title))&limit=6") as? [String: Any],
              let list = (search["data"] as? [[String: Any]])?.filter({ ($0["id"] as? NSNumber) != nil || ($0["id"] as? String) != nil }),
              !list.isEmpty
        else {
            return json(.notFound, ["error": "AniLibria has no release for that title"], cors: cors)
        }

        let wanted = title.lowercased()
        var best = list[0]

        for item in list {
            if titles(of: item).contains(where: { name in
                name == wanted || name.contains(wanted) || wanted.contains(name)
            }) {
                best = item
                break
            }
        }

        guard let identifier = stringValue(best["id"]),
              let full = anilibriaJSON("/anime/releases/\(encodedQuery(identifier))") as? [String: Any],
              let episodes = (full["episodes"] as? [[String: Any]])?.sorted(by: { ordinal($0) < ordinal($1) }),
              !episodes.isEmpty
        else {
            return json(.notFound, ["error": "AniLibria release has no episodes"], cors: cors)
        }

        let target = episodes.first(where: { ordinal($0) == episode })
            ?? episodes[min(episodes.count, episode) - 1]

        guard let hls = ["hls_1080", "hls_720", "hls_480"]
            .compactMap({ target[$0] as? String })
            .first(where: { !$0.isEmpty })
        else {
            return json(.notFound, ["error": "AniLibria has no HLS for that episode"], cors: cors)
        }

        let clean = hls
            .replacingOccurrences(of: "&isWithVideoAds=1", with: "")
            .replacingOccurrences(of: "isWithVideoAds=1", with: "")
            .replacingOccurrences(of: "&isWithVideoAdsAlways=1", with: "")
            .replacingOccurrences(of: "isWithVideoAdsAlways=1", with: "")

        let name = best["name"] as? [String: Any]
        let label = (name?["english"] as? String) ?? (name?["main"] as? String) ?? title

        return json(.ok, [
            "url": clean,
            "type": "hls",
            "quality": "auto",
            "referer": "https://anilibria.top/",
            "subtitles": [],
            "title": label,
            "episode": ordinal(target)
        ], cors: cors)
    }

    private static func anilibriaJSON(_ path: String) -> Any? {
        anilibriaLock.lock()
        if let hit = anilibriaCache[path], Date().timeIntervalSince(hit.at) < 600 {
            anilibriaLock.unlock()
            return hit.value
        }
        anilibriaLock.unlock()

        guard let url = URL(string: anilibriaAPI + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PocketHost", forHTTPHeaderField: "User-Agent")

        let result = fetch(request)
        guard let data = result.data,
              (200..<300).contains(result.response.statusCode),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        anilibriaLock.lock()
        anilibriaCache[path] = (Date(), value)
        if anilibriaCache.count > 60 {
            anilibriaCache.removeAll()
        }
        anilibriaLock.unlock()

        return value
    }

    private static func titles(of release: [String: Any]) -> [String] {
        let name = release["name"] as? [String: Any]
        return [name?["main"], name?["english"], name?["alternative"], release["alias"]]
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func ordinal(_ episode: [String: Any]) -> Int {
        if let number = episode["ordinal"] as? NSNumber { return number.intValue }
        if let text = episode["ordinal"] as? String { return Int(text) ?? 0 }
        return 0
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: - Playlists and subtitles

    private static func rewritePlaylist(_ text: String, base: URL, referer: String?) -> String {
        let lines = text.components(separatedBy: "\n")
        var output: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                output.append(line)
                continue
            }

            if trimmed.hasPrefix("#") {
                output.append(replaceURIAttributes(in: line, base: base, referer: referer))
                continue
            }

            if let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL {
                output.append(proxied(resolved.absoluteString, referer: referer))
            } else {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private static func replaceURIAttributes(in text: String, base: URL, referer: String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#) else { return text }

        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var output = ""
        var cursor = text.startIndex

        for match in regex.matches(in: text, options: [], range: full) {
            guard let whole = Range(match.range, in: text),
                  let uriRange = Range(match.range(at: 1), in: text),
                  let resolved = URL(string: String(text[uriRange]), relativeTo: base)?.absoluteURL
            else { continue }

            output += text[cursor..<whole.lowerBound]
            output += "URI=\"" + proxied(resolved.absoluteString, referer: referer) + "\""
            cursor = whole.upperBound
        }

        output += text[cursor...]
        return output
    }

    private static func proxied(_ target: String, referer: String?) -> String {
        var value = "/api/proxy?url=" + encodedQuery(target)
        if let referer, !referer.isEmpty {
            value += "&ref=" + encodedQuery(referer)
        }
        return value
    }

    private static func toVTT(_ text: String) -> String {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") { return source }

        var body = source
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: #"(\d{2}:\d{2}:\d{2}),(\d{3})"#, with: "$1.$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d{2}:\d{2}),(\d{3})"#, with: "$1.$2", options: .regularExpression)

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "WEBVTT\n\n" + body + "\n"
    }

    // MARK: - Networking

    private struct Upstream {
        let data: Data?
        let file: URL?
        let response: HTTPURLResponse
        let error: String?
    }

    private static func fallbackResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://localhost")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func fetch(_ request: URLRequest) -> Upstream {
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var response: URLResponse?
        var failure: String?

        let task = URLSession.shared.dataTask(with: request) { body, urlResponse, error in
            data = body
            response = urlResponse
            if let error { failure = error.localizedDescription }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return Upstream(data: nil, file: nil, response: fallbackResponse(for: request, status: 504), error: "The stream server took too long to answer.")
        }

        let http = (response as? HTTPURLResponse) ?? fallbackResponse(for: request, status: 502)
        return Upstream(data: data, file: nil, response: http, error: failure)
    }

    private static func download(_ request: URLRequest) -> Upstream {
        let semaphore = DispatchSemaphore(value: 0)
        var file: URL?
        var response: URLResponse?
        var failure: String?

        let task = URLSession.shared.downloadTask(with: request) { location, urlResponse, error in
            response = urlResponse
            if let error {
                failure = error.localizedDescription
            } else if let location {
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pockethost-stream-" + UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: location, to: copy)
                    file = copy
                } catch {
                    failure = "The stream could not be kept on the phone."
                }
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            task.cancel()
            return Upstream(data: nil, file: nil, response: fallbackResponse(for: request, status: 504), error: "The stream server took too long to answer.")
        }

        let http = (response as? HTTPURLResponse) ?? fallbackResponse(for: request, status: 502)
        return Upstream(data: nil, file: file, response: http, error: failure)
    }

    // MARK: - Helpers

    private static func query(_ name: String, in request: HTTPRequest) -> String? {
        guard let query = request.query else { return nil }

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == Substring(name) else { continue }
            return String(parts[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
        }

        return nil
    }

    private static func encodedQuery(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func isPrivateHost(_ raw: String) -> Bool {
        let host = raw.lowercased()
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("[") || host.contains(":") { return true }
        if !host.contains(".") { return true }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }

        let a = parts[0]
        let b = parts[1]
        if a == 0 || a == 10 || a == 127 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        return a >= 224
    }

    private static func textResponse(_ body: String, type: String, status: Int, cors: Bool) -> HTTPResponse {
        let data = Data(body.utf8)
        var headers: [String: String] = [
            "Content-Type": type,
            "Cache-Control": "no-store",
            "Content-Length": String(data.count)
        ]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }

        let code = (100..<600).contains(status) ? status : 200
        return HTTPResponse(
            status: HTTPStatus(code: code, reason: code == 200 ? "OK" : "Upstream"),
            headers: headers,
            body: .data(data)
        )
    }

    private static func json(_ status: HTTPStatus, _ payload: [String: Any], cors: Bool) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var headers: [String: String] = [
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Length": String(data.count)
        ]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }

        return HTTPResponse(status: status, headers: headers, body: .data(data))
    }
}
