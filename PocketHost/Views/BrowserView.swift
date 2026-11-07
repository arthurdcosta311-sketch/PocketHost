//
//  BrowserView.swift
//  PocketHost
//
//  The WebView that renders whatever the server is handing out.
//

import SwiftUI
import UIKit
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var browser: BrowserModel
    @EnvironmentObject private var store: HostingStore

    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            addressBar

            ZStack(alignment: .top) {
                WebViewContainer(model: browser)

                if browser.isLoading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }

                if isWaitingForServer {
                    serverOffCard
                }
            }

            if let message = browser.errorMessage, !isWaitingForServer {
                errorBanner(message)
            }
        }
        .safeAreaInset(edge: .bottom) {
            controls
        }
        .onAppear {
            if store.isRunning && !browser.hasContent {
                browser.loadCurrentAddress()
            }
        }
        .onChange(of: store.isRunning) { _, running in
            guard running else { return }

            // The server just came up: finish whatever was waiting instead of
            // sitting on a dead page until someone taps reload.
            if browser.hasContent {
                browser.retryFailedLoad()
            } else {
                browser.loadCurrentAddress()
            }
        }
    }

    // MARK: - Server state

    private var isLocalAddress: Bool {
        let address = browser.addressField.lowercased()
        return address.contains("localhost") || address.contains("127.0.0.1")
    }

    private var isWaitingForServer: Bool {
        !store.isRunning && isLocalAddress && !browser.hasContent
    }

    private var serverOffCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(store.isStarting ? "Starting the server…" : "The server is off")
                    .font(.headline)

                Text(store.isStarting
                     ? "This page loads the moment the listener is ready."
                     : "PocketHost has to be serving for \(browser.addressField) to open.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    store.start()
                } label: {
                    Label("Start server", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)

                Button("Retry") { browser.loadCurrentAddress() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(24)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .animation(.snappy, value: store.isRunning)
    }

    // MARK: - Address bar

    private var addressBar: some View {
        HStack(spacing: 10) {
            Image(systemName: browser.currentURL.hasPrefix("https://") ? "lock.fill" : "globe")
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Enter an address", text: $browser.addressField)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    addressFocused = false
                    browser.loadCurrentAddress()
                }

            if browser.isLoading {
                Button {
                    browser.stopLoading()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop loading")
            } else {
                Button {
                    browser.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 0) {
            controlButton("chevron.backward", enabled: browser.canGoBack) {
                browser.goBack()
            }
            controlButton("chevron.forward", enabled: browser.canGoForward) {
                browser.goForward()
            }

            Spacer(minLength: 0)

            controlButton("house", enabled: true) {
                browser.loadHome()
            }
            controlButton("arrow.clockwise", enabled: true) {
                browser.reload()
            }

            Spacer(minLength: 0)

            Button {
                openInSafari()
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(browser.currentURL.isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar)
    }

    private func controlButton(
        _ systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
    }

    private func openInSafari() {
        guard let url = browser.webView.url else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.footnote)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button("Retry") { browser.retryFailedLoad() }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let model: BrowserModel

    func makeUIView(context: Context) -> WKWebView {
        let webView = model.webView
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    BrowserView()
        .environmentObject(BrowserModel())
        .environmentObject(HostingStore())
}
