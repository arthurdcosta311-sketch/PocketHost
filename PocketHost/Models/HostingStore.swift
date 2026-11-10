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

    /// Ask the router to forward the port, so the site is reachable from
    /// outside the local network as well.
    @Published var globalAccess: Bool {
        didSet {
            persist()
            applyGlobalPolicy()
        }
    }

    /// The public GitHub repository a published copy of the site goes to.
    @Published var publishRepo: String {
        didSet { persist() }
    }

    /// Publish to this account's own `<username>.github.io` site, which serves
    /// at the root of the address instead of a folder under it.
    @Published var publishUserSite: Bool {
        didSet { persist() }
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

    @Published private(set) var deviceRunCount = 0
    @Published private(set) var lastDeviceRun: Date?
    @Published private(set) var prefetchSummaries: [RuntimePreloader.Summary] = []
    @Published private(set) var preloadedBytes: Int64 = 0
    @Published private(set) var deviceStoredBytes: Int64 = 0
    @Published private(set) var deviceStoredCount = 0

    /// The address the internet can reach, when the router agreed to forward
    /// the port or the phone has a global IPv6 address of its own.
    @Published private(set) var globalURL: String?
    @Published private(set) var globalStatus = "Off"

    let files: FileStore
    let background = BackgroundKeeper()
    let global = GlobalAccess()
    let publisher = WebPublisher()
    var nodeRuntime = NodeRuntimeManager()

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
        static let deviceRunner = "pockethost.deviceRunner"
        static let prefetchRuntimes = "pockethost.prefetchRuntimes"
        static let cachesOnDevice = "pockethost.cacheOnDevice"
        static let globalAccess = "pockethost.globalAccess"
        static let publishRepo = "pockethost.publishRepo"
        static let publishUserSite = "pockethost.publishUserSite"
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
        self.deviceRunnerEnabled = defaults.object(forKey: Keys.deviceRunner) as? Bool ?? true
        self.prefetchRuntimes = defaults.object(forKey: Keys.prefetchRuntimes) as? Bool ?? true
        self.cachesOnDevice = defaults.object(forKey: Keys.cachesOnDevice) as? Bool ?? true
        self.globalAccess = defaults.object(forKey: Keys.globalAccess) as? Bool ?? false
        self.publishRepo = defaults.string(forKey: Keys.publishRepo) ?? "pockethost-site"
        self.publishUserSite = defaults.object(forKey: Keys.publishUserSite) as? Bool ?? false

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

        global.onStateChange = { [weak self] state in
            self?.apply(state)
        }

        publisher.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        nodeRuntime.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        nodeRuntime.onActivityChange = { [weak self] _ in
            self?.applyBackgroundPolicy()
            self?.applyScreenPolicy()
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
            applyGlobalPolicy()

        case .stopped:
            isStarting = false
            isRunning = false
            startedAt = nil
            runner.stop()
            global.stop()
            applyBackgroundPolicy()
            applyScreenPolicy()

        case .failure(let message):
            isStarting = false
            isRunning = false
            lastError = message
            runner.stop()
            global.stop()
            applyBackgroundPolicy()
            applyScreenPolicy()

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
        background.setKeepAlive((isRunning || nodeRuntime.isActive) && backgroundHosting)
    }

    private func applyScreenPolicy() {
        UIApplication.shared.isIdleTimerDisabled = (isRunning || nodeRuntime.isActive) && keepScreenAwake
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

    /// A port mapping only means something while the listener is up.
    private func applyGlobalPolicy() {
        if globalAccess, isRunning {
            global.start(port: UInt16(clamping: port))
        } else {
            global.stop()
        }
    }

    private func apply(_ state: GlobalAccess.State) {
        switch state {
        case .off:
            globalURL = nil
            globalStatus = "Off"

        case .searching:
            globalURL = nil
            globalStatus = "Asking the router for a port…"

        case .available(let url, let method):
            globalURL = url
            globalStatus = "Public through the router · \(method)"

        case .unavailable(let reason):
            globalURL = nil
            globalStatus = reason
        }
    }

    // MARK: - Publishing

    /// Every GitHub Pages site the linked token can see.
    @Published private(set) var sites: [WebPublisher.Site] = []
    @Published private(set) var sitesLoading = false
    @Published private(set) var sitesError: String?

    func refreshSites() {
        guard let token = ApiKeyManager.shared.get(key: "GITHUB_PUBLISH_TOKEN"),
              !sitesLoading
        else { return }

        sitesLoading = true
        sitesError = nil

        Task { @MainActor in
            do {
                sites = try await publisher.sites(token: token)
            } catch {
                sitesError = error.localizedDescription
            }
            sitesLoading = false
        }
    }

    /// Brings a published site's files into the hosted folder so they can be
    /// edited here; the next publish writes them back to the same repository.
    func edit(_ site: WebPublisher.Site) {
        guard let token = ApiKeyManager.shared.get(key: "GITHUB_PUBLISH_TOKEN") else { return }

        Task { @MainActor in
            publisher.noteWorking("Downloading \(site.displayName)…")
            do {
                let downloaded = try await publisher.download(site: site, token: token)
                try files.replaceAll(with: downloaded)
                refreshStats()
                publishRepo = site.repo
                publishUserSite = site.isUserSite
                publisher.noteFinished(url: site.url)
            } catch {
                publisher.noteFailed(error.localizedDescription)
            }
        }
    }

    /// Copies the hosted folder to a public GitHub repository and turns Pages
    /// on, which gives the site an address that works without any router setup.
    func publishSite() {
        guard let token = ApiKeyManager.shared.get(key: "GITHUB_PUBLISH_TOKEN") else { return }

        let repo = publishRepo
        let root = files.root
        let userSite = publishUserSite

        Task { @MainActor in
            await publisher.publish(repo: repo, token: token, root: root, userSite: userSite)
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
        defaults.set(deviceRunnerEnabled, forKey: Keys.deviceRunner)
        defaults.set(prefetchRuntimes, forKey: Keys.prefetchRuntimes)
        defaults.set(cachesOnDevice, forKey: Keys.cachesOnDevice)
        defaults.set(globalAccess, forKey: Keys.globalAccess)
        defaults.set(publishRepo, forKey: Keys.publishRepo)
        defaults.set(publishUserSite, forKey: Keys.publishUserSite)
    }
}
