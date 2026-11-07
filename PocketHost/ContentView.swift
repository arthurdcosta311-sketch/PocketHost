//
//  ContentView.swift
//  PocketHost
//

import SwiftUI

enum AppTab: Hashable {
    case home
    case files
    case browser
}

final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var browserRequest: BrowserRequest?

    struct BrowserRequest: Equatable, Identifiable {
        let id = UUID()
        let url: URL
    }

    func openInBrowser(_ url: URL) {
        browserRequest = BrowserRequest(url: url)
        selectedTab = .browser
    }
}

struct ContentView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            ServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
                .tag(AppTab.home)

            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(AppTab.files)

            BrowserView()
                .tabItem { Label("Browser", systemImage: "safari") }
                .tag(AppTab.browser)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(HostingStore())
        .environmentObject(AppRouter())
        .environmentObject(BrowserModel())
}
