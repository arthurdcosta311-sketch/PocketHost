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
            let files = try collect(root: root)

            state = .working("Checking the GitHub token…")
            let login = try await account(token: token)
            let handle = login.lowercased()

            let name = userSite ? "\(handle).github.io" : Self.repoName(repo)
            guard !name.isEmpty else {
                throw PublishError(message: "Enter a repository name first.")
            }

            try await ensureRepository(owner: login, repo: name, token: token)

            for (index, file) in files.enumerated() {
                state = .working("Uploading \(index + 1) of \(files.count)…")
                try await upload(file, owner: login, repo: name, token: token)
            }

            state = .working("Turning on GitHub Pages…")
            try await enablePages(owner: login, repo: name, token: token)

            let url = userSite
                ? "https://\(handle).github.io/"
                : "https://\(handle).github.io/\(name)/"
            lastPublished = Date()
            state = .done(url: url)
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

    private func ensureRepository(owner: String, repo: String, token: String) async throws {
        var (_, status) = try await request(
            "GET",
            "https://api.github.com/repos/\(owner)/\(repo)",
            token: token,
            body: nil
        )

        if status == 200 { return }
        guard status == 404 else { throw failure(status, doing: "look for the repository") }

        let body = try JSONSerialization.data(withJSONObject: [
            "name": repo,
            "private": false,
            "auto_init": true
        ])

        (_, status) = try await request(
            "POST",
            "https://api.github.com/user/repos",
            token: token,
            body: body
        )

        guard status == 201 || status == 200 else {
            throw failure(status, doing: "create the repository")
        }
    }

    private func upload(_ file: (path: String, data: Data), owner: String, repo: String, token: String) async throws {
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
            "branch": "main"
        ]
        if let sha { payload["sha"] = sha }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let (_, result) = try await request("PUT", url, token: token, body: body)

        guard result == 200 || result == 201 else {
            throw failure(result, doing: "upload \(file.path)")
        }
    }

    private func enablePages(owner: String, repo: String, token: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "source": ["branch": "main", "path": "/"]
        ])

        let (_, status) = try await request(
            "POST",
            "https://api.github.com/repos/\(owner)/\(repo)/pages",
            token: token,
            body: body
        )

        // 201 means it is on now; 409 means it was already on.
        guard status == 201 || status == 409 || status == 204 else {
            throw failure(status, doing: "turn on GitHub Pages")
        }
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

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { continue }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }

            let path = url.path
                .replacingOccurrences(of: root.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

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
