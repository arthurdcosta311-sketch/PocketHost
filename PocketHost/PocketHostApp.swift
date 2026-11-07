//
//  PocketHostApp.swift
//  PocketHost
//

import SwiftUI

@main
struct PocketHostApp: App {
    @StateObject private var store = HostingStore()
    @StateObject private var router = AppRouter()
    @StateObject private var browser = BrowserModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(browser)
                .onAppear {
                    if let url = URL(string: store.localURLString) {
                        browser.setHome(url)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    store.handleScenePhase(phase)
                }
                .onChange(of: store.port) { _, newValue in
                    if let url = URL(string: "http://localhost:\(newValue)/") {
                        browser.setHome(url)
                    }
                }
                .onChange(of: router.browserRequest) { _, request in
                    guard let request else { return }
                    browser.load(request.url)
                }
        }
    }
}
