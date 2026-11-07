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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
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
                ShareSiteSheet(url: store.lanURLString ?? store.localURLString)
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

                    Button { showingShare = true } label: {
                        Image(systemName: "qrcode")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(store.lanURLString == nil)
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
        shareable: Bool
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

                Text(url ?? "Join a Wi-Fi network to share")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                    Button { showingShare = true } label: {
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
            HStack {
                Text("Live requests")
                    .font(.subheadline.weight(.semibold))

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
    }

    // MARK: - Footnote

    private var footnote: some View {
        Text("Serving from On My iPhone › PocketHost › www. iOS pauses the server while PocketHost is in the background, so keep the app open while hosting.")
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
