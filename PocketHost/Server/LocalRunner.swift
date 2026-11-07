//
//  LocalRunner.swift
//  PocketHost
//
//  Runs the hosted site on the device itself, so the runtime is actually
//  exercised even while no other machine is asking for anything.
//
//  It issues plain GET requests for the entry page and the same-origin links
//  found in it, tagged with a header so the request log can tell them apart
//  from real clients. It never synthesises taps, keystrokes, controls or key
//  maps: anything interactive still needs a real connected device to ask.
//

import Foundation

final class LocalRunner {
    /// Asked before each run; lets the store keep quiet while a real client is
    /// actively using the site.
    var shouldRun: (() -> Bool)?
    /// Called on the main queue with how many documents were fetched.
    var onRun: ((Int) -> Void)?

    private let session: URLSession
    private var timer: Timer?
    private var port = 8080
    private var running = false
    private var busy = false

    private(set) var lastRun: Date?
    private(set) var runCount = 0

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func start(port: Int, interval: TimeInterval = 15) {
        stop()

        self.port = port
        running = true

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
        busy = false
    }

    // MARK: - Running

    private func tick() {
        guard running, !busy else { return }
        guard shouldRun?() ?? true else { return }
        guard let base = URL(string: "http://127.0.0.1:\(port)/") else { return }

        busy = true

        request(base) { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.running else {
                    self.busy = false
                    return
                }

                let links = data
                    .flatMap { String(data: $0, encoding: .utf8) }
                    .map { Self.sameOriginLinks(in: $0, limit: 3) } ?? []

                self.fetchAll(links, base: base, index: 0) {
                    self.busy = false
                    self.lastRun = Date()
                    self.runCount += 1 + links.count
                    self.onRun?(1 + links.count)
                }
            }
        }
    }

    private func fetchAll(_ paths: [String], base: URL, index: Int, done: @escaping () -> Void) {
        guard index < paths.count else {
            done()
            return
        }

        guard let url = URL(string: paths[index], relativeTo: base) else {
            fetchAll(paths, base: base, index: index + 1, done: done)
            return
        }

        request(url) { [weak self] _ in
            DispatchQueue.main.async {
                self?.fetchAll(paths, base: base, index: index + 1, done: done)
            }
        }
    }

    private func request(_ url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        request.setValue("1", forHTTPHeaderField: "X-PocketHost-Device-Run")
        request.setValue("PocketHost-DeviceRunner/1.0", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, _, _ in
            completion(data)
        }.resume()
    }

    private static func linkRegex() -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "href\\s*=\\s*[\"'](/[^\"'#>?]*)", options: [.caseInsensitive])
    }

    private static func sameOriginLinks(in html: String, limit: Int) -> [String] {
        guard let regex = linkRegex() else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var paths: [String] = []

        for match in regex.matches(in: html, options: [], range: range) {
            guard let captured = Range(match.range(at: 1), in: html) else { continue }

            let path = String(html[captured])
            if path.isEmpty || paths.contains(path) { continue }

            paths.append(path)
            if paths.count >= limit { break }
        }

        return paths
    }
}
