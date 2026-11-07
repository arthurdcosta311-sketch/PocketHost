//
//  HostingStore.swift
//  PocketHost
//
//  Owns the server, its settings and the live request feed the UI shows.
//

import Foundation
import UIKit

final class HostingStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var lastError: String?
    @Published private(set) var activity: [HTTPLogEntry] = []
    @Published private(set) var requestCount = 0
    @Published private(set) var bytesServed: Int64 = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var lanAddress: String?
    @Published private(set) var fileCount = 0

    @Published var port: Int {
        didSet {
            persist()
            if isRunning { restart() }
        }
    }

    @Published var directoryListing: Bool {
        didSet {
            persist()
            if isRunning { restart() }
        }
    }

    @Published var corsEnabled: Bool {
        didSet {
            persist()
            if isRunning { restart() }
        }
    }

    @Published var advertiseBonjour: Bool {
        didSet {
            persist()
            if isRunning { restart() }
        }
    }

    @Published var autoStart: Bool {
        didSet { persist() }
    }

    let files: FileStore

    private let server: HTTPServer
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let port = "pockethost.port"
        static let directoryListing = "pockethost.directoryListing"
        static let cors = "pockethost.cors"
        static let bonjour = "pockethost.bonjour"
        static let autoStart = "pockethost.autoStart"
    }

    // MARK: - Life cycle

    init() {
        let files = FileStore()
        self.files = files

        let storedPort = defaults.object(forKey: Keys.port) as? Int ?? 8080
        let safePort = (1024...65535).contains(storedPort) ? storedPort : 8080
        self.port = safePort
        self.directoryListing = defaults.object(forKey: Keys.directoryListing) as? Bool ?? true
        self.corsEnabled = defaults.object(forKey: Keys.cors) as? Bool ?? true
        self.advertiseBonjour = defaults.object(forKey: Keys.bonjour) as? Bool ?? true
        self.autoStart = defaults.object(forKey: Keys.autoStart) as? Bool ?? true

        self.server = HTTPServer(
            configuration: HTTPServer.Configuration(
                root: files.root,
                port: UInt16(clamping: safePort),
                servesDirectoryListings: true,
                allowsCORS: true,
                advertisesBonjour: true,
                displayName: "PocketHost"
            )
        )

        server.onEvent = { [weak self] event in
            self?.handle(event)
        }

        files.seedIfNeeded()
        refreshStats()
        lanAddress = NetworkInfo.localIPv4Address()

        if autoStart {
            start()
        }
    }

    // MARK: - Control

    func start() {
        guard !isRunning, !isStarting else { return }

        lastError = nil
        isStarting = true
        lanAddress = NetworkInfo.localIPv4Address()

        let configuration = HTTPServer.Configuration(
            root: files.root,
            port: UInt16(clamping: max(1024, min(port, 65535))),
            servesDirectoryListings: directoryListing,
            allowsCORS: corsEnabled,
            advertisesBonjour: advertiseBonjour,
            displayName: "PocketHost"
        )

        do {
            try server.start(with: configuration)
        } catch {
            isStarting = false
            isRunning = false
            lastError = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning || isStarting else { return }
        isStarting = false
        server.stop()
    }

    func toggle() {
        if isRunning || isStarting {
            stop()
        } else {
            start()
        }
    }

    func restart() {
        server.stop()
        isRunning = false
        isStarting = false
        start()
    }

    func clearActivity() {
        activity.removeAll()
    }

    // MARK: - Derived values

    var localURLString: String {
        "http://localhost:\(port)/"
    }

    var lanURLString: String? {
        guard let lanAddress else { return nil }
        return "http://\(lanAddress):\(port)/"
    }

    func uptimeText(now: Date = Date()) -> String {
        guard let startedAt else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, remaining)
        }
        return "\(remaining)s"
    }

    func refreshStats() {
        fileCount = files.totalFileCount()
    }

    // MARK: - Server events

    private func handle(_ event: ServerEvent) {
        switch event {
        case .listening:
            isStarting = false
            isRunning = true
            startedAt = Date()
            lanAddress = NetworkInfo.localIPv4Address()
            UIApplication.shared.isIdleTimerDisabled = true

        case .stopped:
            isStarting = false
            isRunning = false
            startedAt = nil
            UIApplication.shared.isIdleTimerDisabled = false

        case .failure(let message):
            isStarting = false
            isRunning = false
            lastError = message
            UIApplication.shared.isIdleTimerDisabled = false

        case .request(let entry):
            requestCount += 1
            bytesServed += entry.bytes
            activity.insert(entry, at: 0)
            if activity.count > 40 {
                activity.removeLast(activity.count - 40)
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(port, forKey: Keys.port)
        defaults.set(directoryListing, forKey: Keys.directoryListing)
        defaults.set(corsEnabled, forKey: Keys.cors)
        defaults.set(advertiseBonjour, forKey: Keys.bonjour)
        defaults.set(autoStart, forKey: Keys.autoStart)
    }
}
