//
//  SitePublisher.swift
//  PocketHost
//
//  Publishes the hosted folder to a static host that serves a domain of the
//  user's own: Netlify and Cloudflare Pages, both of which take a zip upload
//  over HTTPS with a token the account creates for itself. GitHub Pages lives in
//  WebPublisher; this is the path that ends at a real domain.
//

import Combine
import Foundation

final class SitePublisher: ObservableObject {
    // MARK: - Types

    enum Provider: String, CaseIterable, Identifiable {
        case netlify
        case cloudflare

        var id: String { rawValue }

        var title: String {
            switch self {
            case .netlify: return "Netlify"
            case .cloudflare: return "Cloudflare Pages"
            }
        }

        var summary: String {
            switch self {
            case .netlify:
                return "Free HTTPS address, custom domains and instant rollbacks."
            case .cloudflare:
                return "Free unlimited bandwidth on Cloudflare's network, custom domains included."
            }
        }

        /// The key ApiKeyManager keeps this provider's token under.
        var tokenKey: String {
            switch self {
            case .netlify: return "NETLIFY_TOKEN"
            case .cloudflare: return "CLOUDFLARE_API_TOKEN"
            }
        }

        var tokenPage: String {
            switch self {
            case .netlify: return "https://app.netlify.com/user/applications#personal-access-tokens"
            case .cloudflare: return "https://dash.cloudflare.com/profile/api-tokens"
            }
        }

        var needsAccountID: Bool { self == .cloudflare }
    }

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

        var message: String? {
            switch self {
            case .working(let step): return step
            case .failed(let reason): return reason
            default: return nil
            }
        }
    }

    struct Deployment: Identifiable, Equatable, Codable {
        var id = UUID()
        let url: String
        let provider: String
        let date: Date
    }

    struct DomainReport: Equatable {
        let domain: String
        let addresses: [String]
        let canonicalName: String?
        let httpStatus: Int?
        let httpsStatus: Int?

        var resolves: Bool { !addresses.isEmpty }
    }

    struct DNSRecord: Identifiable, Equatable {
        let type: String
        let name: String
        let value: String

        var id: String { "\(type) \(name) \(value)" }
    }

    struct PublishError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var deployments: [Deployment] = []
    @Published private(set) var domainReport: DomainReport?
    @Published private(set) var domainChecking = false

    private let session: URLSession
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let deployments = "pockethost.deployments"
        static let netlifySite = "pockethost.netlifySiteID"
        static let cloudflareProject = "pockethost.cloudflareProject"
        static let publishedURL = "pockethost.publishedURL"
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)

        if let data = defaults.data(forKey: Keys.deployments),
           let stored = try? JSONDecoder().decode([Deployment].self, from: data) {
            deployments = stored
        }
    }

    // MARK: - Deploy

    /// Publishes the folder to `provider` and, when a domain is given, points
    /// that domain at the deployment.
    @MainActor
    func deploy(
        provider: Provider,
        root: URL,
        siteName: String,
        domain: String,
        accountID: String
    ) async {
        guard !state.isWorking else { return }

        let token = ApiKeyManager.shared.get(key: provider.tokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            state = .failed("Add a \(provider.title) token in Settings first.")
            return
        }

        let name = Self.slug(siteName.isEmpty ? "pockethost-site" : siteName)
        let cleanDomain = Self.domain(domain)

        do {
            state = .working("Reading the hosted folder…")
            let files = try collect(root: root)
            guard !files.isEmpty else {
                throw PublishError(message: "There is nothing in the hosted folder to publish.")
            }

            let archive = ZipWriter.archive(files)
            state = .working("Uploading \(files.count) files…")

            let url: String
            switch provider {
            case .netlify:
                url = try await deployNetlify(
                    archive: archive,
                    files: files.count,
                    name: name,
                    token: token,
                    domain: cleanDomain
                )
            case .cloudflare:
                url = try await deployCloudflare(
                    archive: archive,
                    name: name,
                    token: token,
                    accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines),
                    domain: cleanDomain
                )
            }

            record(url: url, provider: provider)
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

    // MARK: - Netlify

    private func deployNetlify(
        archive: Data,
        files: Int,
        name: String,
        token: String,
        domain: String
    ) async throws -> String {
        var siteID = defaults.string(forKey: Keys.netlifySite)

        if siteID == nil {
            state = .working("Creating the Netlify site…")
            let body = try JSONSerialization.data(withJSONObject: ["name": name])
            let (data, status) = try await request(
                "POST",
                "https://api.netlify.com/api/v1/sites",
                token: token,
                body: body,
                contentType: "application/json"
            )
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String
            else {
                throw failure(status, doing: "create the Netlify site", provider: .netlify)
            }
            siteID = id
            defaults.set(id, forKey: Keys.netlifySite)
        }

        guard let siteID else {
            throw PublishError(message: "Netlify did not return a site to deploy to.")
        }

        state = .working("Uploading \(files) files to Netlify…")
        let (deployData, deployStatus) = try await request(
            "POST",
            "https://api.netlify.com/api/v1/sites/\(siteID)/deploys",
            token: token,
            body: archive,
            contentType: "application/zip"
        )
        guard (200..<300).contains(deployStatus),
              let deploy = try? JSONSerialization.jsonObject(with: deployData) as? [String: Any],
              let deployID = deploy["id"] as? String
        else {
            throw failure(deployStatus, doing: "upload the site to Netlify", provider: .netlify)
        }

        var siteURL = deploy["ssl_url"] as? String
            ?? deploy["url"] as? String
            ?? ""

        state = .working("Waiting for Netlify to build the site…")
        for _ in 0..<45 {
            let (statusData, statusCode) = try await request(
                "GET",
                "https://api.netlify.com/api/v1/sites/\(siteID)/deploys/\(deployID)",
                token: token,
                body: nil,
                contentType: nil
            )
            if statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] {
                if let ssl = json["ssl_url"] as? String, !ssl.isEmpty { siteURL = ssl }
                switch json["state"] as? String {
                case "ready": break
                case "error":
                    throw PublishError(message: json["error_message"] as? String ?? "Netlify could not build the site.")
                default:
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                break
            }
            try await Task.sleep(for: .seconds(2))
        }

        guard !siteURL.isEmpty else {
            throw PublishError(message: "Netlify accepted the upload but did not report an address.")
        }

        if !domain.isEmpty {
            state = .working("Connecting \(domain)…")
            let body = try JSONSerialization.data(withJSONObject: ["custom_domain": domain])
            let (_, status) = try await request(
                "PATCH",
                "https://api.netlify.com/api/v1/sites/\(siteID)",
                token: token,
                body: body,
                contentType: "application/json"
            )
            if (200..<300).contains(status) {
                return "https://\(domain)/"
            }
            return Self.https(siteURL)
        }

        return Self.https(siteURL)
    }

    // MARK: - Cloudflare Pages

    private func deployCloudflare(
        archive: Data,
        name: String,
        token: String,
        accountID: String,
        domain: String
    ) async throws -> String {
        guard !accountID.isEmpty else {
            throw PublishError(message: "Cloudflare needs the account ID from its dashboard as well as a token.")
        }

        let base = "https://api.cloudflare.com/client/v4/accounts/\(accountID)/pages/projects"
        var project = defaults.string(forKey: Keys.cloudflareProject) ?? name

        state = .working("Creating the Cloudflare Pages project…")
        let createBody = try JSONSerialization.data(withJSONObject: [
            "name": project,
            "production_branch": "main"
        ])
        let (createData, createStatus) = try await request(
            "POST",
            base,
            token: token,
            body: createBody,
            contentType: "application/json"
        )

        if (200..<300).contains(createStatus) {
            if let json = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let created = result["name"] as? String {
                project = created
            }
            defaults.set(project, forKey: Keys.cloudflareProject)
        } else if let json = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
                  let errors = json["errors"] as? [[String: Any]],
                  errors.contains(where: { ($0["code"] as? Int) == 800_0000 || ($0["message"] as? String ?? "").contains("already exists") }) {
            // The project is already there, which is exactly what a second
            // publish wants.
        } else if !(createStatus == 409) {
            throw failure(createStatus, doing: "create the Cloudflare Pages project", provider: .cloudflare)
        }

        state = .working("Uploading the site to Cloudflare Pages…")
        let boundary = "pockethost-\(UUID().uuidString)"
        let body = multipart(
            boundary: boundary,
            fields: ["branch": "main"],
            file: (name: "site.zip", data: archive)
        )
        let (deployData, deployStatus) = try await request(
            "POST",
            "\(base)/\(project)/deployments",
            token: token,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )

        guard (200..<300).contains(deployStatus),
              let json = try? JSONSerialization.jsonObject(with: deployData) as? [String: Any],
              let result = json["result"] as? [String: Any]
        else {
            throw failure(deployStatus, doing: "upload the site to Cloudflare Pages", provider: .cloudflare)
        }

        var deploymentID = result["id"] as? String
        var siteURL = result["url"] as? String ?? ""

        if let id = deploymentID {
            state = .working("Waiting for Cloudflare to finish the deployment…")
            for _ in 0..<45 {
                let (statusData, statusCode) = try await request(
                    "GET",
                    "\(base)/\(project)/deployments/\(id)",
                    token: token,
                    body: nil,
                    contentType: nil
                )
                if statusCode == 200,
                   let statusJSON = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any],
                   let deployment = statusJSON["result"] as? [String: Any] {
                    if let url = deployment["url"] as? String, !url.isEmpty { siteURL = url }
                    let stage = deployment["latest_stage"] as? [String: Any]
                    switch stage?["status"] as? String {
                    case "success": break
                    case "failure", "canceled":
                        throw PublishError(message: stage?["name"] as? String ?? "Cloudflare could not finish the deployment.")
                    default:
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }
            deploymentID = nil
        }

        if !domain.isEmpty {
            state = .working("Connecting \(domain)…")
            let body = try JSONSerialization.data(withJSONObject: ["name": domain])
            let (_, status) = try await request(
                "POST",
                "\(base)/\(project)/domains",
                token: token,
                body: body,
                contentType: "application/json"
            )
            if (200..<300).contains(status) {
                return "https://\(domain)/"
            }
            return "https://\(project).pages.dev/"
        }

        if !siteURL.isEmpty { return Self.https(siteURL) }
        return "https://\(project).pages.dev/"
    }

    // MARK: - Domain check

    /// Resolves the domain, follows its CNAME when the system resolver reports
    /// one, and asks it for a page, so the app can say whether a domain really
    /// reaches the deployment yet.
    func check(domain raw: String, provider: Provider) {
        let domain = Self.domain(raw)
        guard !domain.isEmpty, !domainChecking else { return }

        domainChecking = true
        domainReport = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            let addresses = DNSLookup.addresses(for: domain)
            let canonical = DNSLookup.canonicalName(for: domain)
            let http = await Self.status(of: "http://\(domain)/")
            let https = await Self.status(of: "https://\(domain)/")

            let report = DomainReport(
                domain: domain,
                addresses: addresses,
                canonicalName: canonical,
                httpStatus: http,
                httpsStatus: https
            )

            await MainActor.run {
                self?.domainReport = report
                self?.domainChecking = false
            }
        }
    }

    /// The records to create at the registrar, for the provider in use.
    func records(for provider: Provider, domain: String) -> [DNSRecord] {
        let domain = Self.domain(domain)
        guard !domain.isEmpty else { return [] }
        let label = domain.split(separator: ".").dropFirst().joined(separator: ".")

        switch provider {
        case .netlify:
            let host = netlifyHost
            return [
                DNSRecord(type: "A", name: "@", value: "75.2.60.5"),
                DNSRecord(type: "CNAME", name: "www", value: host.isEmpty ? "your-site.netlify.app" : host)
            ]
        case .cloudflare:
            let host = cloudflareHost
            return [
                DNSRecord(type: "CNAME", name: "@", value: host),
                DNSRecord(type: "CNAME", name: "www", value: host)
            ]
        }
    }

    var netlifyHost: String {
        guard let url = deployments.first(where: { $0.provider == Provider.netlify.rawValue })?.url,
              let host = URL(string: url)?.host else { return "" }
        return host.hasSuffix("netlify.app") ? host : ""
    }

    var cloudflareHost: String {
        guard let url = deployments.first(where: { $0.provider == Provider.cloudflare.rawValue })?.url,
              let host = URL(string: url)?.host else { return "" }
        return host.hasSuffix("pages.dev") ? host : ""
    }

    // MARK: - Requests

    private func request(
        _ method: String,
        _ address: String,
        token: String,
        body: Data?,
        contentType: String?
    ) async throws -> (Data, Int) {
        guard let url = URL(string: address) else {
            throw PublishError(message: "That provider address could not be read.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("PocketHost", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func failure(_ status: Int, doing action: String, provider: Provider) -> PublishError {
        switch status {
        case 401, 403:
            return PublishError(message: "\(provider.title) refused the token while trying to \(action). Create a new one and paste it in Settings.")
        case 404:
            return PublishError(message: "\(provider.title) could not find what it needed to \(action). Check the account ID and the site name.")
        case 422, 400:
            return PublishError(message: "\(provider.title) rejected the request to \(action). A site with that name may already belong to another account.")
        case 429:
            return PublishError(message: "\(provider.title) is rate limiting this account. Wait a minute and publish again.")
        default:
            return PublishError(message: "\(provider.title) answered \(status) while trying to \(action).")
        }
    }

    private func multipart(
        boundary: String,
        fields: [String: String],
        file: (name: String, data: Data)
    ) -> Data {
        var body = Data()

        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.name)\"\r\n".utf8))
        body.append(Data("Content-Type: application/zip\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        return body
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
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path

        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }

            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }

            let path = String(full.dropFirst(base.count + 1))
            guard !path.isEmpty, !path.contains("/.") else { continue }

            total += data.count
            output.append((path, data))
            if output.count >= 300 || total > 60 * 1024 * 1024 { break }
        }

        return output
    }

    // MARK: - Recording

    @MainActor
    private func record(url: String, provider: Provider) {
        defaults.set(url, forKey: Keys.publishedURL)
        var updated = deployments.filter { $0.url != url }
        updated.insert(Deployment(url: url, provider: provider.rawValue, date: Date()), at: 0)
        deployments = Array(updated.prefix(12))

        if let data = try? JSONEncoder().encode(deployments) {
            defaults.set(data, forKey: Keys.deployments)
        }
    }

    // MARK: - Helpers

    static func domain(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") {
            text = String(text[range.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let colon = text.firstIndex(of: ":"), text[colon...].dropFirst().allSatisfy({ $0.isNumber }) {
            text = String(text[..<colon])
        }
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func slug(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .map { character in character.unicodeScalars.allSatisfy(allowed.contains) ? String(character) : "-" }
            .joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "pockethost-site" : String(trimmed.prefix(50))
    }

    private static func https(_ url: String) -> String {
        guard !url.isEmpty else { return url }
        if url.hasPrefix("http://") { return "https://" + url.dropFirst("http://".count) }
        if url.hasPrefix("https://") { return url }
        return "https://\(url)"
    }

    private static func status(of address: String) async -> Int? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpMethod = "GET"
        request.setValue("PocketHost", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}
