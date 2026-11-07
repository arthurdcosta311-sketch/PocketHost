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

    /// Refuse any single response that would need more than the 512 MB ceiling
    /// in memory. Turning it off keeps the detection but streams instead.
    @Published var refuseOversized: Bool {
        didSet {
            persist()
            MemoryGuard.shared.refusesOversized = refuseOversized
        }
    }

    /// Run the hosted site on this device when nobody else is asking for it.
    @Published var deviceRunnerEnabled: Bool {
        didSet {
            persist()
            applyRunnerPolicy()
        }
    }

    /// Let the devices that connect keep the files they fetched in their own
    /// cache, so the assets live there rather than on this phone.
    @Published var cachesOnDevice: Bool {
        didSet {
            persist()
            if isRunning { restart() }
        }
    }

    /// Detect the runtimes a page needs and tell the client to fetch them
    /// before it asks for them one by one.
    @Published var prefetchRuntimes: Bool {
        didSet {
            persist()
            RuntimePreloader.shared.isEnabled = prefetchRuntimes
            if !prefetchRuntimes {
                RuntimePreloader.shared.resetHistory()
            }
        }
    }

    @Published private(set) var guardDetections: [MemoryGuard.Detection] = []
    @Published private(set) var deviceRunCount = 0
    @Published private(set) var lastDeviceRun: Date?
    @Published private(set) var prefetchSummaries: [RuntimePreloader.Summary] = []
    @Published private(set) var preloadedBytes: Int64 = 0
    @Published private(set) var deviceStoredBytes: Int64 = 0
    @Published private(set) var deviceStoredCount = 0

    let files: FileStore
    let background = BackgroundKeeper()

    private let server: HTTPServer
    private let runner = LocalRunner()
    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []
    private var lastRemoteRequestAt: Date?

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
        static let refuseOversized = "pockethost.refuseOversized"
        static let deviceRunner = "pockethost.deviceRunner"
        static let prefetchRuntimes = "pockethost.prefetchRuntimes"
        static let cachesOnDevice = "pockethost.cacheOnDevice"
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
        self.refuseOversized = defaults.object(forKey: Keys.refuseOversized) as? Bool ?? false
        self.deviceRunnerEnabled = defaults.object(forKey: Keys.deviceRunner) as? Bool ?? true
        self.prefetchRuntimes = defaults.object(forKey: Keys.prefetchRuntimes) as? Bool ?? true
        self.cachesOnDevice = defaults.object(forKey: Keys.cachesOnDevice) as? Bool ?? true

        self.server = HTTPServer(
            configuration: HTTPServer.Configuration(
                root: files.root,
                port: UInt16(clamping: safePort),
                servesDirectoryListings: true,
                allowsCORS: true,
                advertisesBonjour: true,
                displayName: "PocketHost",
                cachesOnDevice: true
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

        MemoryGuard.shared.refusesOversized = refuseOversized
        MemoryGuard.shared.onDetection = { [weak self] detection in
            guard let self else { return }
            self.guardDetections.insert(detection, at: 0)
            if self.guardDetections.count > 5 {
                self.guardDetections.removeLast(self.guardDetections.count - 5)
            }
        }

        runner.shouldRun = { [weak self] in
            guard let self, self.deviceRunnerEnabled, self.isRunning else { return false }
            guard let lastRemoteRequestAt = self.lastRemoteRequestAt else { return true }
            return Date().timeIntervalSince(lastRemoteRequestAt) > 20
        }
        runner.onRun = { [weak self] count in
            guard let self else { return }
            self.deviceRunCount += count
            self.lastDeviceRun = Date()
        }

        RuntimePreloader.shared.isEnabled = prefetchRuntimes
        RuntimePreloader.shared.onPreload = { [weak self] summary in
            guard let self else { return }
            self.prefetchSummaries.insert(summary, at: 0)
            if self.prefetchSummaries.count > 5 {
                self.prefetchSummaries.removeLast(self.prefetchSummaries.count - 5)
            }
            self.preloadedBytes += summary.bytes
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

        wantsToBeRunning = true
        lastError = nil
        isStarting = true
        lanAddress = NetworkInfo.localIPv4Address()

        // If the preferred port is busy, walk upwards instead of going offline.
        // The browser's home address follows the change through `port`.
        let preferred = max(1024, min(port, 65535))
        let chosen = NetworkInfo.firstAvailablePort(startingAt: preferred)
        if chosen != port {
            port = chosen
        }

        let configuration = HTTPServer.Configuration(
            root: files.root,
            port: UInt16(clamping: max(1024, min(port, 65535))),
            servesDirectoryListings: directoryListing,
            allowsCORS: corsEnabled,
            advertisesBonjour: advertiseBonjour,
            displayName: "PocketHost",
            cachesOnDevice: cachesOnDevice
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
            applyRunnerPolicy()

        case .stopped:
            isStarting = false
            isRunning = false
            startedAt = nil
            runner.stop()
            background.setKeepAlive(false)
            UIApplication.shared.isIdleTimerDisabled = false

        case .failure(let message):
            isStarting = false
            isRunning = false
            lastError = message
            runner.stop()
            background.setKeepAlive(false)
            UIApplication.shared.isIdleTimerDisabled = false

        case .request(let entry):
            // Traffic, however idle, renews the lease with iOS.
            background.extend()

            guard entry.origin == .remote else {
                deviceRunCount += 1
                lastDeviceRun = entry.date
                return
            }

            lastRemoteRequestAt = entry.date
            requestCount += 1
            bytesServed += entry.bytes
            if entry.storesOnDevice {
                deviceStoredBytes += entry.bytes
                deviceStoredCount += 1
            }
            activity.insert(entry, at: 0)
            if activity.count > 40 {
                activity.removeLast(activity.count - 40)
            }
        }
    }

    // MARK: - Keep-alive policy

    private func applyBackgroundPolicy() {
        background.setKeepAlive(isRunning && backgroundHosting)
    }

    private func applyScreenPolicy() {
        UIApplication.shared.isIdleTimerDisabled = isRunning && keepScreenAwake
    }

    /// The runner only works while there is a listener to talk to, and only
    /// while the user wants the device to exercise the site on its own.
    private func applyRunnerPolicy() {
        if isRunning, deviceRunnerEnabled {
            runner.start(port: port)
        } else {
            runner.stop()
        }
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
        defaults.set(refuseOversized, forKey: Keys.refuseOversized)
        defaults.set(deviceRunnerEnabled, forKey: Keys.deviceRunner)
        defaults.set(prefetchRuntimes, forKey: Keys.prefetchRuntimes)
        defaults.set(cachesOnDevice, forKey: Keys.cachesOnDevice)
    }
}
