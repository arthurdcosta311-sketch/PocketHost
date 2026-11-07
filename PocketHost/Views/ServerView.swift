//
//  ServerView.swift
//  PocketHost
//

import SwiftUI

struct ServerView: View {
    @EnvironmentObject private var store: HostingStore
    @EnvironmentObject private var router: AppRouter

    @State private var showingSettings = false
    @State private var showingShare = false
    @State private var shareURL: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    backgroundCard
                    guardCard
                    addressesCard
                    statsRow
                    activityCard
                    footnote
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("PocketHost")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingShare) {
                ShareSiteSheet(url: shareURL ?? store.lanURLString ?? store.localURLString)
            }
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LiveDot(active: store.isRunning)

                Text(store.isRunning ? "Online" : (store.isStarting ? "Starting" : "Offline"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(store.isRunning ? Color.accentColor : Color.secondary)

                Spacer()

                Text("PORT \(store.port)")
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(store.isRunning ? "Your site is live" : "Your files are offline")
                    .font(.system(.title2, design: .rounded).weight(.bold))

                Text(store.isRunning
                     ? "Serving the www folder over HTTP on this device and on your local network."
                     : "Start the server to host HTML, CSS, JavaScript, images and any other file over HTTP.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if store.isRunning {
                    Button(role: .destructive) {
                        store.stop()
                    } label: {
                        Label("Stop server", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        shareURL = store.globalURL ?? store.lanURLString
                        showingShare = true
                    } label: {
                        Image(systemName: "qrcode")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled((store.globalURL ?? store.lanURLString) == nil)
                    .accessibilityLabel("Share your site")
                } else {
                    Button {
                        store.start()
                    } label: {
                        HStack(spacing: 8) {
                            if store.isStarting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Starting…")
                            } else {
                                Image(systemName: "play.fill")
                                Text("Start server")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(store.isStarting)
                }
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(
                    store.isRunning ? Color.accentColor.opacity(0.35) : Color.clear,
                    lineWidth: 1
                )
        )
        .shadow(
            color: store.isRunning ? Color.accentColor.opacity(0.16) : .clear,
            radius: 22, y: 8
        )
    }

    // MARK: - Addresses

    private var addressesCard: some View {
        VStack(spacing: 0) {
            addressRow(
                title: "This device",
                url: store.localURLString,
                systemImage: "iphone",
                tint: .accentColor,
                shareable: false
            )

            Divider().padding(.leading, 62)

            addressRow(
                title: "Local network",
                url: store.lanURLString,
                systemImage: "wifi",
                tint: .orange,
                shareable: true
            )

            Divider().padding(.leading, 62)

            addressRow(
                title: "Internet",
                url: store.globalURL,
                systemImage: "globe",
                tint: .green,
                shareable: store.globalURL != nil,
                placeholder: store.globalAccess ? store.globalStatus : "Off · turn it on in Settings"
            )

            if let published = store.publisher.state.url {
                Divider().padding(.leading, 62)

                addressRow(
                    title: "Published",
                    url: published,
                    systemImage: "paperplane",
                    tint: .purple,
                    shareable: true
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func addressRow(
        title: String,
        url: String?,
        systemImage: String,
        tint: Color,
        shareable: Bool,
        placeholder: String = "Join a Wi-Fi network to share"
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.weight(.semibold))

                Text(url ?? placeholder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if let url {
                Button {
                    if let parsed = URL(string: url) {
                        router.openInBrowser(parsed)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open \(title) in the browser")

                CopyButton(text: url)

                if shareable {
                    Button {
                        shareURL = url
                        showingShare = true
                    } label: {
                        Image(systemName: "qrcode")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show a QR code")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatTile(
                value: "\(store.requestCount)",
                label: "Requests",
                systemImage: "arrow.down.left"
            )

            TimelineView(.periodic(from: Date(), by: 1)) { context in
                StatTile(
                    value: store.uptimeText(now: context.date),
                    label: "Uptime",
                    systemImage: "clock"
                )
            }

            StatTile(
                value: "\(store.fileCount)",
                label: "Files",
                systemImage: "doc.on.doc"
            )
        }
    }

    // MARK: - Activity

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Live requests")
                    .font(.subheadline.weight(.semibold))

                Text("\(store.requestCount)")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .contentTransition(.numericText())

                Spacer()

                if !store.activity.isEmpty {
                    Button("Clear") { store.clearActivity() }
                        .font(.footnote)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if store.activity.isEmpty {
                Text(store.isRunning
                     ? "No requests yet. Open your site to watch them arrive."
                     : "Start the server to see requests stream in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                let entries = Array(store.activity.prefix(8))
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ActivityRow(entry: entry)
                        if entry.id != entries.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .animation(.snappy(duration: 0.22), value: store.requestCount)
    }

    // MARK: - Background

    private var backgroundCard: some View {
        HStack(spacing: 12) {
            Image(systemName: backgroundIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(backgroundTint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(backgroundTint.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Background hosting")
                    .font(.footnote.weight(.semibold))

                Text(backgroundDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if store.background.needsAttention {
                Button("Allow") { store.background.requestPermission() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var backgroundDetail: String {
        guard store.backgroundHosting else {
            return "Off. iOS pauses the server once PocketHost leaves the screen."
        }

        switch store.background.state {
        case .active:
            return "On. The server keeps answering with the screen off, until you stop it."
        case .needsPermission:
            return "Allow Location so iOS keeps PocketHost running in the background."
        case .denied:
            return "Location is off for PocketHost, so iOS can pause the server. Enable it in Settings."
        case .limited:
            return "Running on a short lease. iOS may pause the server."
        case .off:
            return "Starts together with the server."
        }
    }

    private var backgroundIcon: String {
        guard store.backgroundHosting else { return "moon.zzz.fill" }

        switch store.background.state {
        case .active: return "location.fill"
        case .needsPermission, .denied, .limited: return "exclamationmark.triangle.fill"
        case .off: return "moon.zzz.fill"
        }
    }

    private var backgroundTint: Color {
        guard store.backgroundHosting else { return Color.secondary }

        switch store.background.state {
        case .active: return Color.accentColor
        case .needsPermission, .denied, .limited: return Color.orange
        case .off: return Color.secondary
        }
    }

    // MARK: - Runtime guard

    private var guardCard: some View {
        VStack(spacing: 0) {
            memoryRow

            Divider().padding(.leading, 62)

            prefetchRow

            Divider().padding(.leading, 62)

            runnerRow
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var memoryRow: some View {
        TimelineView(.periodic(from: Date(), by: 2)) { _ in
            HStack(spacing: 14) {
                Image(systemName: "memorychip")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.purple.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Memory")
                        .font(.footnote.weight(.semibold))

                    Text(memoryDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private var memoryDetail: String {
        "App using \(MemoryFootprint.text()) · no ceiling, every file streams"
    }

    private var prefetchRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.blue.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Device cache")
                    .font(.footnote.weight(.semibold))

                Text(prefetchDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: $store.cachesOnDevice)
                .labelsHidden()
                .accessibilityLabel("Cache files on connected devices")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var prefetchDetail: String {
        guard store.cachesOnDevice else {
            return "Off. Responses say no-store, so a connected device keeps nothing."
        }

        let stored = deviceStoredText

        guard store.prefetchRuntimes else {
            return "\(stored) · runtime preloading is off"
        }

        guard let summary = store.prefetchSummaries.first else {
            return "\(stored) · every page goes out with preload hints for its runtimes"
        }

        var counts: [String: Int] = [:]
        for dependency in summary.dependencies {
            counts[dependency.kind.label, default: 0] += 1
        }
        let kinds = counts
            .sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")

        let total = summary.dependencies.count
        return "\(stored) · \(summary.documentPath): \(total) runtime\(total == 1 ? "" : "s") handed to the client\(kinds.isEmpty ? "" : " (\(kinds))")"
    }

    private var deviceStoredText: String {
        guard store.deviceStoredCount > 0 else {
            return "Nothing kept by a connected device yet"
        }

        let size = FileStore.sizeText(store.deviceStoredBytes)
        let count = store.deviceStoredCount
        return "\(size) in \(count) asset\(count == 1 ? "" : "s") kept by the devices that connected"
    }

    private var runnerRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.teal.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("On-device runner")
                    .font(.footnote.weight(.semibold))

                Text(runnerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Toggle("", isOn: $store.deviceRunnerEnabled)
                .labelsHidden()
                .accessibilityLabel("Run the site on this device when idle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var runnerDetail: String {
        guard store.deviceRunnerEnabled else {
            return "Off. Pages only run when a connected device asks for them."
        }

        if let last = store.lastDeviceRun {
            return "\(store.deviceRunCount) runs on this device · last \(last.formatted(date: .omitted, time: .shortened))"
        }

        return "Runs page loads itself when nothing else is asking. Controls and key maps stay with connected devices."
    }

    // MARK: - Footnote

    private var footnote: some View {
        Text("Serving from On My iPhone › PocketHost › www. Background hosting keeps the listener alive through low-power location updates. Stopping the server or force-quitting the app ends it.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

#Preview {
    ServerView()
        .environmentObject(HostingStore())
        .environmentObject(AppRouter())
}
