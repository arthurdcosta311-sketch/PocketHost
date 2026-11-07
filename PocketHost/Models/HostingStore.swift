//
//  HostingStore.swift
//  PocketHost
//
//  Owns the server, its settings, the live request feed the UI shows and the
//  background keep-alive that stops iOS suspending the listener.
//

import Combine
import Foundation
import SwiftUI
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

    /// Keep serving after the app leaves the screen, using low-power location
    /// updates to stay out of the suspended state.
    @Published var backgroundHosting: Bool {
        didSet {
            persist()
            applyBackgroundPolicy()
        }
    }

    @Published var keepScreenAwake: Bool {
        didSet {
            persist()
            applyScreenPolicy()
        }
    }

    let files: FileStore
    let background = BackgroundKeeper()

    private let server: HTTPServer
    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []

    /// Whether the user asked for the server to be up, independently of
    /// whether iOS has got round to telling us it really is.
    private(set) var wantsToBeRunning = false

    private enum Keys {
        static let port = "pockethost.port"
        static let directoryListing = "pockethost.directoryListing"
        static let cors = "pockethost.cors"
        static let bonjour = "pockethost.bonjour"
        static let autoStart = "pockethost.autoStart"
        static let backgroundHosting = "pockethost.backgroundHosting"
        static let keepScreenAwake = "pockethost.keepScreenAwake"
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
        self.backgroundHosting = defaults.object(forKey: Keys.backgroundHosting) as? Bool ?? true
        self.keepScreenAwake = defaults.object(forKey: Keys.keepScreenAwake) as? Bool ?? true

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

        // The keeper is its own observable object; forward its changes so the
        // screens that only know about the store still refresh.
        background.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

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

        wantsToBeRunning = true
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
            wantsToBeRunning = false
        }
    }

    func stop() {
        wantsToBeRunning = false
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

    /// Called from the app's scene phase changes. Coming back to the screen
    /// after a long time in the background is when iOS is most likely to have
    /// pulled the listener out from under us.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if wantsToBeRunning && !isRunning && !isStarting {
                lastError = nil
                start()
            } else {
                applyBackgroundPolicy()
                applyScreenPolicy()
            }

        case .background:
            applyBackgroundPolicy()

        default:
            break
        }
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
            applyBackgroundPolicy()
            applyScreenPolicy()

        case .stopped:
            isStarting = false
            isRunning = false
            startedAt = nil
            background.setKeepAlive(false)
            UIApplication.shared.isIdleTimerDisabled = false

        case .failure(let message):
            isStarting = false
            isRunning = false
            lastError = message
            background.setKeepAlive(false)
            UIApplication.shared.isIdleTimerDisabled = false

        case .request(let entry):
            requestCount += 1
            bytesServed += entry.bytes
            activity.insert(entry, at: 0)
            if activity.count > 40 {
                activity.removeLast(activity.count - 40)
            }
            // Traffic, however idle, renews the lease with iOS.
            background.extend()
        }
    }

    // MARK: - Keep-alive policy

    private func applyBackgroundPolicy() {
        background.setKeepAlive(isRunning && backgroundHosting)
    }

    private func applyScreenPolicy() {
        UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenAwake
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(port, forKey: Keys.port)
        defaults.set(directoryListing, forKey: Keys.directoryListing)
        defaults.set(corsEnabled, forKey: Keys.cors)
        defaults.set(advertiseBonjour, forKey: Keys.bonjour)
        defaults.set(autoStart, forKey: Keys.autoStart)
        defaults.set(backgroundHosting, forKey: Keys.backgroundHosting)
        defaults.set(keepScreenAwake, forKey: Keys.keepScreenAwake)
    }
}
