//
//  SettingsView.swift
//  PocketHost
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: HostingStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    @State private var portText = ""
    @State private var tokenText = ""
    @State private var deployTokenText = ""
    @State private var showingRestore = false
    @State private var restoreNote: String?
    @State private var siteToEdit: WebPublisher.Site?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("8080", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .onSubmit { applyPort() }
                    }

                    Toggle("Folder listings", isOn: $store.directoryListing)
                    Toggle("Allow cross-origin requests", isOn: $store.corsEnabled)
                    Toggle("Advertise on Bonjour", isOn: $store.advertiseBonjour)
                    Toggle("Start automatically", isOn: $store.autoStart)
                    Toggle("Open to the internet", isOn: $store.globalAccess)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Changing the port restarts a running server. Use a value between 1024 and 65535.\n\nOpening to the internet asks your router for a TCP port mapping (NAT-PMP, then UPnP), and falls back to this device's global IPv6 address when no router will open one. The address is shown on the Server tab. A router without either feature, or a provider that hides everything behind its own address, cannot be reached this way.")
                }

                Section {
                    Toggle("Keep hosting in the background", isOn: $store.backgroundHosting)
                    Toggle("Keep the screen awake while hosting", isOn: $store.keepScreenAwake)

                    if store.backgroundHosting {
                        LabeledContent("Background mode", value: backgroundStateText)

                        if store.background.needsAttention {
                            Button(store.background.authorizationStatus == .denied
                                   ? "Open Location settings"
                                   : "Allow location access") {
                                store.background.requestPermission()
                            }
                        }
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("iOS suspends a backgrounded app within seconds, which would drop every request. PocketHost asks for \u{201C}While Using\u{201D} location only to stay out of that suspended state: updates are the coarsest available (about a kilometre apart) and no location is stored or sent anywhere. Hosting keeps answering with the screen off until you stop the server or iOS ends the app. This needs the Location background mode, and App Store review may ask you about it.")
                }

                Section {
                    Toggle("Cache files on connected devices", isOn: $store.cachesOnDevice)
                    Toggle("Preload page runtimes", isOn: $store.prefetchRuntimes)
                    Toggle("Run the site on-device when idle", isOn: $store.deviceRunnerEnabled)
                } header: {
                    Text("Runtimes")
                } footer: {
                    Text("Runtimes are kept by the devices that connect, not by this phone. Every page the server hands out is scanned for what it needs — scripts, modules, styles, fonts, images, WebAssembly and workers, including what its stylesheets pull in — and that list travels with the page as preload hints, so the client downloads those files straight away and stores them in its own cache. Pages revalidate every time, so an edit shows up on the next load, while assets stay on the client for a minute and are then revalidated in the background. Turning caching off sends no-store instead. There is no memory ceiling: files of every size are streamed in chunks, and the Server tab just reports what the app is using. The on-device runner fetches the entry page and its same-origin links by itself so the runtime stays warm without another device asking. It only issues GET requests — it never synthesises taps, keystrokes, controls or key maps, so anything interactive still needs a real client.")
                }

                Section {
                    if ApiKeyManager.shared.has(key: "GITHUB_PUBLISH_TOKEN") {
                        LabeledContent("Token", value: "Saved in the keychain")

                        Button("Remove token", role: .destructive) {
                            ApiKeyManager.shared.remove(key: "GITHUB_PUBLISH_TOKEN")
                            tokenText = ""
                        }
                    } else {
                        SecureField("Paste your own token", text: $tokenText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("Save token") {
                            let value = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            if ApiKeyManager.shared.set(key: "GITHUB_PUBLISH_TOKEN", value: value) {
                                tokenText = ""
                            }
                        }
                        .disabled(tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button("Create a token on GitHub") {
                        if let url = URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=PocketHost") {
                            router.openInBrowser(url)
                        }
                    }
                    .font(.footnote)
                } header: {
                    Text("GitHub account")
                } footer: {
                    Text("Every account makes its own token, so nothing is shared between users: create one with the repo scope on GitHub, paste it here once, and PocketHost keeps it in this phone's keychain and nowhere else.")
                }

                Section {
                    if store.sitesLoading {
                        HStack {
                            Text("Looking for your sites…")
                            Spacer()
                            ProgressView()
                        }
                    } else if store.sites.isEmpty {
                        Text(store.sitesError ?? "No GitHub Pages sites yet. Publish one and it appears here.")
                            .font(.footnote)
                            .foregroundStyle(store.sitesError == nil ? Color.secondary : Color.red)
                    } else {
                        ForEach(store.sites) { site in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(site.displayName)
                                    .font(.subheadline.weight(.semibold))

                                Text(site.url)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                HStack(spacing: 18) {
                                    Button("View") {
                                        if let url = URL(string: site.url) {
                                            router.openInBrowser(url)
                                        }
                                    }

                                    Button("Edit") {
                                        siteToEdit = site
                                    }
                                }
                                .font(.footnote)
                            }
                            .padding(.vertical, 3)
                        }
                    }

                    Button("Refresh sites") {
                        store.refreshSites()
                    }
                    .disabled(store.sitesLoading)
                } header: {
                    Text("Your GitHub Pages sites")
                } footer: {
                    Text("Edit brings a site's files into the hosted folder so you can change them here; the next publish writes them back to that same repository. View opens it in the browser.")
                }

                Section {
                    Picker("Host", selection: $store.deployProvider) {
                        ForEach(SitePublisher.Provider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    Text(store.deployProvider.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if ApiKeyManager.shared.has(key: store.deployProvider.tokenKey) {
                        LabeledContent("Token", value: "Saved in the keychain")

                        Button("Remove token", role: .destructive) {
                            ApiKeyManager.shared.remove(key: store.deployProvider.tokenKey)
                            deployTokenText = ""
                        }
                    } else {
                        SecureField("Paste your \(store.deployProvider.title) token", text: $deployTokenText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button("Save token") {
                            let value = deployTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            if ApiKeyManager.shared.set(key: store.deployProvider.tokenKey, value: value) {
                                deployTokenText = ""
                            }
                        }
                        .disabled(deployTokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Button("Create a token at \(store.deployProvider.title)") {
                        if let url = URL(string: store.deployProvider.tokenPage) {
                            router.openInBrowser(url)
                        }
                    }
                    .font(.footnote)

                    if store.deployProvider.needsAccountID {
                        TextField("Account ID", text: $store.cloudflareAccountID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Text("Site name")
                        Spacer()
                        TextField("pockethost-site", text: $store.deploySiteName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Text("Domain")
                        Spacer()
                        TextField("example.com", text: $store.deployDomain)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }

                    Button {
                        store.deploySite()
                    } label: {
                        HStack {
                            Text("Publish to \(store.deployProvider.title)")

                            if store.sitePublisher.state.isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.sitePublisher.state.isWorking)

                    if let message = store.sitePublisher.state.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(store.sitePublisher.state.url == nil ? Color.secondary : Color.green)
                    }

                    if let url = store.sitePublisher.state.url {
                        HStack {
                            Text(url)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Open") {
                                if let parsed = URL(string: url) {
                                    router.openInBrowser(parsed)
                                }
                            }
                            .font(.footnote)
                        }
                    }
                } header: {
                    Text("Publish to your own domain")
                } footer: {
                    Text("Copies the hosted folder to Netlify or Cloudflare Pages and, when a domain is filled in, points that domain at the new deployment. Both are free for static sites, both serve https, and both keep the domain across redeploys. The token is created by your own account and kept in this phone's keychain.")
                }

                Section {
                    HStack {
                        Text("Domain")
                        Spacer()
                        Text(store.deployDomain.isEmpty ? "Set it above" : store.deployDomain)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        store.checkDomain()
                    } label: {
                        HStack {
                            Text("Check the domain")

                            if store.sitePublisher.domainChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.deployDomain.isEmpty || store.sitePublisher.domainChecking)

                    if let report = store.sitePublisher.domainReport {
                        LabeledContent("Resolves to", value: report.resolves ? report.addresses.prefix(2).joined(separator: ", ") : "Nothing yet")

                        if let canonical = report.canonicalName {
                            LabeledContent("Points at", value: canonical)
                        }

                        LabeledContent("Answering", value: report.httpsStatus.map { "https · \($0)" }
                            ?? report.httpStatus.map { "http · \($0)" }
                            ?? "No answer")

                        Text(report.resolves && report.httpsStatus != nil
                             ? "The domain is live."
                             : "DNS can take a few minutes after the records below are saved at your registrar.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.sitePublisher.records(for: store.deployProvider, domain: store.deployDomain)) { record in
                        HStack(spacing: 10) {
                            Text(record.type)
                                .font(.caption.weight(.semibold).monospaced())
                                .frame(width: 52, alignment: .leading)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name)
                                    .font(.system(.caption, design: .monospaced))
                                Text(record.value)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 6)

                            CopyButton(text: record.value)
                        }
                    }
                } header: {
                    Text("Your domain's DNS")
                } footer: {
                    Text("Add these records where the domain's DNS is managed, then check the domain. The site's own address keeps working either way.")
                }

                Section {
                    Toggle("Use my username.github.io site", isOn: $store.publishUserSite)

                    if !store.publishUserSite {
                        HStack {
                            Text("Repository")
                            Spacer()
                            TextField("pocket-host-site", text: $store.publishRepo)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }

                    if let url = store.publisher.state.url {
                        LabeledContent("Published at", value: url)
                    }

                    Button {
                        store.publishSite()
                    } label: {
                        HStack {
                            Text("Publish site to GitHub Pages")

                            if store.publisher.state.isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.publisher.state.isWorking)

                    if case let .working(step) = store.publisher.state {
                        Text(step)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if case let .failed(reason) = store.publisher.state {
                        Text(reason)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Publish to the web")
                } footer: {
                    Text("Copies the hosted folder to GitHub and turns GitHub Pages on, so the site has a permanent https address that works from anywhere — no router to configure. With the username.github.io option it goes to your own GitHub Pages site and lives at the root of the address; otherwise it goes to the named repository and lives at username.github.io/repository/. Pages serves static files only, and a published site is a snapshot until you publish again.")
                }

                Section {
                    LabeledContent("Hosted folder", value: "www")
                    LabeledContent("Files", value: "\(store.fileCount)")
                    Button("Restore sample sites") { showingRestore = true }
                } header: {
                    Text("Content")
                } footer: {
                    Text("Restoring writes index.html, the WebGL demo and the capability lab back into the folder. Your own files are left alone.")
                }

                Section {
                    LabeledContent("Rendering", value: "WKWebView")
                    LabeledContent("JavaScript", value: "JIT compiled")
                    LabeledContent("Graphics", value: "WebGL 2 · GPU")
                    LabeledContent("Delivery", value: "HTTP/1.1 · Bonjour")
                } header: {
                    Text("Engine")
                } footer: {
                    Text("Pages run in WebKit's multi-process engine, with byte-range support for video and audio.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        applyPort()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                portText = String(store.port)
                if store.sites.isEmpty {
                    store.refreshSites()
                }
            }
            .alert("Replace the hosted files?", isPresented: Binding(
                get: { siteToEdit != nil },
                set: { if !$0 { siteToEdit = nil } }
            )) {
                Button("Replace", role: .destructive) {
                    if let site = siteToEdit {
                        store.edit(site)
                    }
                    siteToEdit = nil
                }
                Button("Cancel", role: .cancel) { siteToEdit = nil }
            } message: {
                Text("Your hosted folder will be replaced with a copy of \(siteToEdit?.displayName ?? "the site"), so you can edit it here. Publishing then writes it back to that repository.")
            }
            .alert("Restore sample sites?", isPresented: $showingRestore) {
                Button("Restore", role: .destructive) {
                    store.files.restoreSamples()
                    store.refreshStats()
                    restoreNote = "Sample sites restored."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This overwrites index.html, the WebGL demo and the capability lab with fresh copies.")
            }
            .overlay(alignment: .bottom) {
                if let restoreNote {
                    Text(restoreNote)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.thinMaterial))
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .task(id: restoreNote) {
                guard restoreNote != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                withAnimation { restoreNote = nil }
            }
        }
    }

    private var backgroundStateText: String {
        switch store.background.state {
        case .off: return "Off"
        case .active: return "On · low-power location"
        case .needsPermission: return "Waiting for permission"
        case .denied: return "Denied"
        case .limited: return "Limited"
        }
    }

    private func applyPort() {
        if let value = Int(portText), (1024...65535).contains(value) {
            store.port = value
        } else {
            portText = String(store.port)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(HostingStore())
        .environmentObject(AppRouter())
}
