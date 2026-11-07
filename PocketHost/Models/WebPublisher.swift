//
//  WebPublisher.swift
//  PocketHost
//
//  Copies the hosted folder to a public GitHub repository and turns GitHub Pages
//  on, so a site whose network cannot be opened from outside still gets a
//  permanent address that works from anywhere.
//

import Combine
import Foundation

final class WebPublisher: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case done(url: String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }

        var url: String? {
            if case .done(let url) = self { return url }
            return nil
        }
    }

    struct PublishError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Site: Identifiable, Equatable {
        let owner: String
        let repo: String
        let url: String
        let isUserSite: Bool
        let updated: Date?

        var id: String { "\(owner)/\(repo)" }
        var displayName: String { isUserSite ? "\(owner).github.io" : repo }
        var detail: String { "\(owner)/\(repo)" }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastPublished: Date?

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
    }

    // MARK: - Publish

    @MainActor
    func publish(repo: String, token: String, root: URL, userSite: Bool) async {
        guard !state.isWorking else { return }

        do {
            state = .working("Reading the hosted folder…")
            let collected = try collect(root: root)

            state = .working("Checking the GitHub token…")
            let login = try await account(token: token)
            let handle = login.lowercased()

            let name = userSite ? "\(handle).github.io" : Self.repoName(repo)
            guard !name.isEmpty else {
                throw PublishError(message: "Enter a repository name first.")
            }

            state = .working("Preparing the repository…")
            let branch = try await ensureRepository(owner: login, repo: name, token: token)
            let files = prepared(collected, title: name, relativize: !userSite)

            for (index, file) in files.enumerated() {
                state = .working("Uploading \(index + 1) of \(files.count)…")
                try await upload(file, owner: login, repo: name, branch: branch, token: token)
            }

            state = .working("Turning on GitHub Pages…")
            try await enablePages(owner: login, repo: name, branch: branch, token: token)

            state = .working("Waiting for GitHub to build the site…")
            let build = await pagesBuild(owner: login, repo: name, token: token)

            if let failure = build.error {
                throw PublishError(message: failure)
            }

            let fallback = userSite
                ? "https://\(handle).github.io/"
                : "https://\(handle).github.io/\(name)/"

            lastPublished = Date()
            state = .done(url: build.url ?? fallback)
        } catch let error as PublishError {
            state = .failed(error.message)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    func reset() {
        guard !state.isWorking else { return }
        state = .idle
    }

    static func repoName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .map { character in character.unicodeScalars.allSatisfy(allowed.contains) ? String(character) : "-" }
            .joined()
        return String(cleaned.prefix(100))
    }

    // MARK: - GitHub

    private func account(token: String) async throws -> String {
        let (data, status) = try await request(
            "GET",
            "https://api.github.com/user",
            token: token,
            body: nil
        )

        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String,
              !login.isEmpty
        else {
            throw failure(status, doing: "read the account behind that token")
        }

        return login
    }

    /// Creates the repository when it is missing and reports which branch it
    /// serves from, so uploads and Pages land on the same one.
    private func ensureRepository(owner: String, repo: String, token: String) async throws -> String {
        let (data, status) = try await request(
            "GET",
            "https://api.github.com/repos/\(owner)/\(repo)",
            token: token,
            body: nil
        )

        if status == 200 {
            return branch(from: data) ?? "main"
        }

        guard status == 404 else { throw failure(status, doing: "look for the repository") }

        let body = try JSONSerialization.data(withJSONObject: [
            "name": repo,
            "private": false,
            "auto_init": true
        ])

        let (created, createdStatus) = try await request(
            "POST",
            "https://api.github.com/user/repos",
            token: token,
            body: body
        )

        guard createdStatus == 201 || createdStatus == 200 else {
            throw failure(createdStatus, doing: "create the repository")
        }

        return branch(from: created) ?? "main"
    }

    private func branch(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["default_branch"] as? String,
              !value.isEmpty
        else { return nil }

        return value
    }

    private func upload(
        _ file: (path: String, data: Data),
        owner: String,
        repo: String,
        branch: String,
        token: String
    ) async throws {
        let url = "https://api.github.com/repos/\(owner)/\(repo)/contents/\(escaped(file.path))"

        // An existing file has to be replaced by its current sha, not created.
        var sha: String?
        let (existing, status) = try await request("GET", url, token: token, body: nil)
        if status == 200,
           let json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
           let value = json["sha"] as? String {
            sha = value
        }

        var payload: [String: Any] = [
            "message": "Publish from PocketHost",
            "content": file.data.base64EncodedString(),
            "branch": branch
        ]
        if let sha { payload["sha"] = sha }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, result) = try await request("PUT", url, token: token, body: body)

        guard result == 200 || result == 201 else {
            throw failure(result, doing: "upload \(file.path)")
        }
    }

    /// Turns Pages on, or points an already-enabled site at the branch that was
    /// just published to. A site left on another branch is the usual reason a
    /// published index never appears.
    private func enablePages(owner: String, repo: String, branch: String, token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "source": ["branch": branch, "path": "/"]
        ])

        let (_, existing) = try await request(
            "GET",
            "https://api.github.com/repos/\(owner)/\(repo)/pages",
            token: token,
            body: nil
        )

        if existing == 200 {
            let (_, updated) = try await request(
                "PUT",
                "https://api.github.com/repos/\(owner)/\(repo)/pages",
                token: token,
                body: body
            )

            guard updated == 204 || updated == 200 else {
                throw failure(updated, doing: "point GitHub Pages at the published branch")
            }
            return
        }

        let (_, status) = try await request(
            "POST",
            "https://api.github.com/repos/\(owner)/\(repo)/pages",
            token: token,
            body: body
        )

        if status == 201 || status == 204 { return }

        if status == 409 {
            let (_, updated) = try await request(
                "PUT",
                "https://api.github.com/repos/\(owner)/\(repo)/pages",
                token: token,
                body: body
            )

            guard updated == 204 || updated == 200 else {
                throw failure(updated, doing: "turn on GitHub Pages")
            }
            return
        }

        throw failure(status, doing: "turn on GitHub Pages")
    }

    /// Waits for the first build and returns the address GitHub reports, which
    /// is authoritative for user sites and repositories alike, plus the reason
    /// when the build failed.
    private func pagesBuild(owner: String, repo: String, token: String) async -> (url: String?, error: String?) {
        var reported: String?
        var lastStatus = ""

        for attempt in 0..<10 {
            let result = try? await request(
                "GET",
                "https://api.github.com/repos/\(owner)/\(repo)/pages",
                token: token,
                body: nil
            )

            if let (data, status) = result, status == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let url = json["html_url"] as? String, !url.isEmpty {
                    reported = url
                }

                let buildStatus = (json["status"] as? String) ?? ""
                lastStatus = buildStatus

                if buildStatus == "built" { return (reported, nil) }

                if buildStatus == "errored" {
                    return (nil, "GitHub could not build the site. Check the repository's Pages settings for the reason.")
                }

                // The first build can take a minute; after a few checks report
                // the address anyway rather than stalling here.
                if attempt >= 4, reported != nil { return (reported, nil) }
            }

            try? await Task.sleep(for: .seconds(3))
        }

        if reported != nil { return (reported, nil) }

        if lastStatus.isEmpty {
            return (nil, "GitHub has not finished setting Pages up. Open the repository's Pages settings in a moment.")
        }

        return (nil, "GitHub is still building the site (\(lastStatus)). Open the published address in a moment.")
    }

    // MARK: - Existing sites

    /// Every repository of the account that has GitHub Pages turned on.
    func sites(token: String) async throws -> [Site] {
        let (data, status) = try await request(
            "GET",
            "https://api.github.com/user/repos?per_page=100&sort=pushed&affiliation=owner",
            token: token,
            body: nil
        )

        guard status == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw failure(status, doing: "list your repositories")
        }

        let formatter = ISO8601DateFormatter()
        var sites: [Site] = []

        for item in list where (item["has_pages"] as? Bool) == true {
            guard let repo = item["name"] as? String,
                  let owner = (item["owner"] as? [String: Any])?["login"] as? String
            else { continue }

            let handle = owner.lowercased()
            let isUserSite = repo.lowercased() == "\(handle).github.io"
            let url = isUserSite
                ? "https://\(handle).github.io/"
                : "https://\(handle).github.io/\(repo)/"
            let updated = (item["pushed_at"] as? String).flatMap { formatter.date(from: $0) }

            sites.append(Site(owner: owner, repo: repo, url: url, isUserSite: isUserSite, updated: updated))
        }

        return sites.sorted { lhs, rhs in
            if lhs.isUserSite != rhs.isUserSite { return lhs.isUserSite }
            return (lhs.updated ?? .distantPast) > (rhs.updated ?? .distantPast)
        }
    }

    /// Downloads a site's files so they can be edited in the hosted folder.
    func download(site: Site, token: String) async throws -> [(path: String, data: Data)] {
        let (repoData, repoStatus) = try await request(
            "GET",
            "https://api.github.com/repos/\(site.owner)/\(site.repo)",
            token: token,
            body: nil
        )

        guard repoStatus == 200, let branch = branch(from: repoData) else {
            throw failure(repoStatus, doing: "read \(site.repo)")
        }

        let (treeData, treeStatus) = try await request(
            "GET",
            "https://api.github.com/repos/\(site.owner)/\(site.repo)/git/trees/\(branch)?recursive=1",
            token: token,
            body: nil
        )

        guard treeStatus == 200,
              let json = try? JSONSerialization.jsonObject(with: treeData) as? [String: Any],
              let tree = json["tree"] as? [[String: Any]]
        else {
            throw failure(treeStatus, doing: "read the files in \(site.repo)")
        }

        var output: [(path: String, data: Data)] = []
        var total = 0

        for item in tree {
            guard (item["type"] as? String) == "blob",
                  let path = item["path"] as? String,
                  !path.hasPrefix("."),
                  !path.contains("/.")
            else { continue }

            guard ((item["size"] as? Int) ?? 0) <= 10 * 1024 * 1024 else { continue }

            let (fileData, fileStatus) = try await request(
                "GET",
                "https://api.github.com/repos/\(site.owner)/\(site.repo)/contents/\(escaped(path))?ref=\(branch)",
                token: token,
                body: nil
            )

            guard fileStatus == 200,
                  let fileJSON = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
                  let content = fileJSON["content"] as? String,
                  let decoded = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: ""))
            else { continue }

            total += decoded.count
            output.append((path, decoded))

            if output.count >= 100 || total > 40 * 1024 * 1024 { break }
        }

        guard !output.isEmpty else {
            throw PublishError(message: "\(site.repo) has no files to bring back.")
        }

        return output
    }

    @MainActor
    func noteWorking(_ message: String) {
        state = .working(message)
    }

    @MainActor
    func noteFinished(url: String) {
        lastPublished = Date()
        state = .done(url: url)
    }

    @MainActor
    func noteFailed(_ message: String) {
        state = .failed(message)
    }

    // MARK: - Requests

    private func request(
        _ method: String,
        _ address: String,
        token: String,
        body: Data?
    ) async throws -> (Data, Int) {
        guard let url = URL(string: address) else {
            throw PublishError(message: "GitHub answered with an address PocketHost could not read.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PocketHost", forHTTPHeaderField: "User-Agent")

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func failure(_ status: Int, doing action: String) -> PublishError {
        switch status {
        case 401:
            return PublishError(message: "GitHub refused the token. Check it is still valid and has the repo scope.")
        case 403, 404:
            return PublishError(message: "GitHub would not let this token \(action). It needs the repo scope, and Pages has to be allowed for the account.")
        case 409:
            return PublishError(message: "GitHub reported a conflict while trying to \(action). Try again in a moment.")
        case 422:
            return PublishError(message: "GitHub rejected the request to \(action). A repository with that name may already exist outside this account.")
        default:
            return PublishError(message: "GitHub answered \(status) while trying to \(action).")
        }
    }

    // MARK: - Page files

    /// Adds the two files GitHub Pages needs: `.nojekyll`, so nothing is run
    /// through Jekyll, and an index at the top when the folder has none, so the
    /// published address has something to serve. A project site lives under
    /// `/repository/`, so root-absolute links would point above it and lose every
    /// style and script: those are rewritten relative to each file.
    private func prepared(
        _ files: [(path: String, data: Data)],
        title: String,
        relativize: Bool
    ) -> [(path: String, data: Data)] {
        var output = files.map { file -> (path: String, data: Data) in
            guard relativize else { return file }

            let lower = file.path.lowercased()
            guard lower.hasSuffix(".html") || lower.hasSuffix(".htm") ||
                  lower.hasSuffix(".css") || lower.hasSuffix(".svg"),
                  let text = String(data: file.data, encoding: .utf8)
            else { return file }

            return (file.path, Data(relativized(text, for: file.path).utf8))
        }

        let paths = Set(files.map { $0.path })

        if !paths.contains(".nojekyll") {
            output.append((".nojekyll", Data()))
        }

        let hasIndex = files.contains { file in
            let lower = file.path.lowercased()
            return lower == "index.html" || lower == "index.htm"
        }

        if !hasIndex {
            let listing = files
                .map { $0.path }
                .filter { !$0.hasPrefix(".") }
                .sorted()

            output.append(("index.html", Data(indexHTML(title: title, paths: listing).utf8)))
        }

        return output
    }

    /// Rewrites `/asset.css` and `url(/font.woff2)` so they resolve from the
    /// file they appear in rather than from the domain root.
    private func relativized(_ text: String, for path: String) -> String {
        let depth = max(0, path.split(separator: "/").count - 1)
        let prefix = depth == 0 ? "" : String(repeating: "../", count: depth)

        var output = replace(
            in: text,
            pattern: #"\b(href|src|action|poster)\s*=\s*(["'])/(?!/)([^"']*)\2"#,
            build: { groups in "\(groups[0])=\(groups[1])\(prefix)\(groups[2])\(groups[1])" }
        )

        output = replace(
            in: output,
            pattern: #"url\(\s*(["']?)/(?!/)([^"')]*)\1\s*\)"#,
            build: { groups in "url(\(groups[0])\(prefix)\(groups[1])\(groups[0]))" }
        )

        return output
    }

    /// Runs a regular expression over a string, handing each match's captured
    /// groups to `build` and keeping everything around them.
    private func replace(
        in text: String,
        pattern: String,
        build: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var output = ""
        var cursor = text.startIndex

        for match in regex.matches(in: text, options: [], range: full) {
            guard let range = Range(match.range, in: text) else { continue }

            var groups: [String] = []
            for index in 1..<match.numberOfRanges {
                if let group = Range(match.range(at: index), in: text) {
                    groups.append(String(text[group]))
                } else {
                    groups.append("")
                }
            }

            output += text[cursor..<range.lowerBound]
            output += build(groups)
            cursor = range.upperBound
        }

        output += text[cursor...]
        return output
    }

    private func indexHTML(title: String, paths: [String]) -> String {
        var items = ""

        for path in paths.prefix(200) {
            let label = escape(path)
            let href = escaped(path)
            items += "<li><a href=\"\(href)\">\(label)</a></li>\n"
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 32px 20px; font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { max-width: 640px; margin: 0 auto; }
        h1 { font-size: 1.4rem; margin: 0 0 4px; }
        p { margin: 0 0 20px; font-size: .9rem; opacity: .7; }
        ul { list-style: none; margin: 0; padding: 0; border-top: 1px solid rgba(128,128,128,.3); }
        li { border-bottom: 1px solid rgba(128,128,128,.3); }
        a { display: block; padding: 11px 2px; color: #0a84ff; text-decoration: none; }
        </style>
        </head>
        <body>
        <main>
        <h1>\(escape(title))</h1>
        <p>Published from PocketHost. The folder had no index page of its own.</p>
        <ul>
        \(items)</ul>
        </main>
        </body>
        </html>
        """
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Files

    private func collect(root: URL) throws -> [(path: String, data: Data)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PublishError(message: "The hosted folder could not be read.")
        }

        var output: [(path: String, data: Data)] = []
        var total = 0

        // The enumerator reports real paths, which can differ from the folder
        // URL by a /private symlink. Resolving both keeps every file at the
        // right place in the repository instead of in a nested copy of the
        // phone's whole path.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }

            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }

            let path = String(full.dropFirst(base.count + 1))
            guard !path.isEmpty else { continue }

            total += data.count
            output.append((path, data))

            if output.count >= 200 || total > 40 * 1024 * 1024 { break }
        }

        guard !output.isEmpty else {
            throw PublishError(message: "There is nothing in the hosted folder to publish.")
        }

        return output
    }

    private func escaped(_ path: String) -> String {
        path
            .split(separator: "/")
            .map { component in
                String(component).addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?%"))
                ) ?? String(component)
            }
            .joined(separator: "/")
    }
}
