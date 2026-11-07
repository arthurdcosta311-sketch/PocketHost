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
            }

            if let message = browser.errorMessage {
                errorBanner(message)
            }
        }
        .safeAreaInset(edge: .bottom) {
            controls
        }
        .onAppear {
            if browser.currentURL.isEmpty {
                browser.loadHome()
            }
        }
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
}
