//
//  BackgroundKeeper.swift
//  PocketHost
//
//  Keeps the process (and therefore the HTTP listener) alive once the app
//  leaves the screen.
//
//  iOS suspends a backgrounded app within seconds, which would silently drop
//  every incoming request. The supported way for an app that is not playing
//  audio, tracking a workout or navigating to keep running is low-power
//  background location updates: CoreLocation wakes the app often enough that
//  the process is never suspended, so the listener keeps answering.
//
//  Location itself is never used, stored or sent anywhere. Accuracy is set to
//  the coarsest value available and the movement filter is 500 m, so the radio
//  is barely used. "While Using the App" permission is enough, and nothing is
//  requested until the user turns hosting on.
//

import CoreLocation
import Foundation
import UIKit

final class BackgroundKeeper: NSObject, ObservableObject {
    enum State: Equatable {
        case off
        case active
        case needsPermission
        case denied
        case limited
    }

    @Published private(set) var state: State = .off
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var keepAliveRequested = false
    private var task: UIBackgroundTaskIdentifier = .invalid
    private var renewalTimer: Timer?

    override init() {
        super.init()

        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        manager.showsBackgroundLocationIndicator = true

        authorizationStatus = manager.authorizationStatus
    }

    // MARK: - State

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isKeepingAlive: Bool {
        keepAliveRequested
    }

    var needsAttention: Bool {
        keepAliveRequested && (state == .needsPermission || state == .denied)
    }

    // MARK: - Control

    /// Turns the keep-alive on or off. Safe to call repeatedly.
    func setKeepAlive(_ enabled: Bool) {
        onMain { [weak self] in
            guard let self else { return }

            self.keepAliveRequested = enabled

            if enabled {
                self.activate()
            } else {
                self.deactivate()
            }
        }
    }

    /// Called whenever a request is served, so an idle-looking server still
    /// renews its lease with iOS.
    func extend() {
        onMain { [weak self] in
            guard let self, self.keepAliveRequested else { return }

            if self.task == .invalid {
                self.beginTask()
            } else {
                self.scheduleRenewal(after: 20)
            }
        }
    }

    /// Asks for "While Using" location access, or opens Settings when the
    /// answer was already no.
    func requestPermission() {
        onMain { [weak self] in
            guard let self else { return }

            switch self.manager.authorizationStatus {
            case .notDetermined:
                self.manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            default:
                break
            }
        }
    }

    // MARK: - Location updates

    private func activate() {
        // Requires UIBackgroundModes = location in Info.plist.
        manager.allowsBackgroundLocationUpdates = true

        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        manager.startUpdatingLocation()
        refreshState()
        beginTask()
    }

    private func deactivate() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        endTask()
        state = .off
    }

    private func refreshState() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        guard keepAliveRequested else {
            state = .off
            return
        }

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            state = .active
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            state = .needsPermission
        @unknown default:
            state = .limited
        }
    }

    // MARK: - Background task lease

    /// A background task is the belt to location's braces: it buys roughly
    /// thirty seconds each time and is renewed in a rolling loop, so even
    /// without location the server gets a little extra time after the app
    /// leaves the screen.
    private func beginTask() {
        // While the app is on screen it cannot be suspended, so no lease is
        // needed; the lease matters from the moment it is left behind.
        guard UIApplication.shared.applicationState != .active else {
            endTask()
            return
        }

        guard task == .invalid else {
            scheduleRenewal(after: 20)
            return
        }

        task = UIApplication.shared.beginBackgroundTask(withName: "PocketHost.KeepServing") { [weak self] in
            self?.endTaskAndRestartIfNeeded()
        }

        scheduleRenewal(after: 20)
    }

    private func scheduleRenewal(after seconds: TimeInterval) {
        renewalTimer?.invalidate()

        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.endTaskAndRestartIfNeeded()
        }
        renewalTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endTaskAndRestartIfNeeded() {
        endTask()
        guard keepAliveRequested else { return }
        beginTask()
    }

    private func endTask() {
        renewalTimer?.invalidate()
        renewalTimer = nil

        guard task != .invalid else { return }
        let identifier = task
        task = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    // MARK: - Threading

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension BackgroundKeeper: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshState()

        guard keepAliveRequested else { return }

        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            beginTask()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The coordinates are deliberately ignored: this keeps the app awake.
        extend()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let locationError = error as? CLError, locationError.code == .locationUnknown {
            return
        }
        if keepAliveRequested {
            state = .limited
        }
    }
}
