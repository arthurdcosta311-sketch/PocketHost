//
//  BrowserModel.swift
//  PocketHost
//
//  The WebView that renders hosted pages. WebKit runs it in its own process
//  with JIT-compiled JavaScript and GPU-backed WebGL.
//

import Foundation
import UIKit
import WebKit

final class BrowserModel: NSObject, ObservableObject {
    @Published var addressField = "http://localhost:8080/"
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageTitle = ""
    @Published private(set) var currentURL = ""
    @Published private(set) var errorMessage: String?

    private var homeURL = URL(string: "http://localhost:8080/")!
    private var observations: [NSKeyValueObservation] = []
    private var lastRequestedURL: URL?

    lazy var webView: WKWebView = makeWebView()

    override init() {
        super.init()
        _ = webView
    }

    // MARK: - Web view

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = view.estimatedProgress
            DispatchQueue.main.async { self?.progress = value }
        })

        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            let value = view.isLoading
            DispatchQueue.main.async { self?.isLoading = value }
        })

        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            let value = view.canGoBack
            DispatchQueue.main.async { self?.canGoBack = value }
        })

        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            let value = view.canGoForward
            DispatchQueue.main.async { self?.canGoForward = value }
        })

        return webView
    }

    // MARK: - Navigation

    func setHome(_ url: URL) {
        homeURL = url
        if currentURL.isEmpty {
            addressField = url.absoluteString
        }
    }

    func load(_ url: URL) {
        errorMessage = nil
        lastRequestedURL = url
        addressField = url.absoluteString
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        webView.load(request)
    }

    func loadHome() {
        load(homeURL)
    }

    /// True once anything has actually rendered.
    var hasContent: Bool {
        webView.url != nil
    }

    /// Reloads whatever failed, e.g. the moment the server comes up, so a page
    /// that was requested while the listener was down appears by itself.
    func retryFailedLoad() {
        guard errorMessage != nil || webView.url == nil else { return }

        if let target = lastRequestedURL ?? Self.normalizedURL(from: addressField) {
            load(target)
        } else {
            loadHome()
        }
    }

    func loadCurrentAddress() {
        guard let url = Self.normalizedURL(from: addressField) else {
            errorMessage = "That does not look like a web address."
            return
        }
        load(url)
    }

    func reload() {
        if webView.url == nil {
            loadHome()
        } else {
            webView.reload()
        }
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") {
            return URL(string: trimmed)
        }

        let isLocal = trimmed.hasPrefix("localhost")
            || trimmed.hasPrefix("127.0.0.1")
            || trimmed.hasPrefix("192.168.")
            || trimmed.hasPrefix("10.")
            || trimmed.hasPrefix("172.")

        if isLocal {
            return URL(string: "http://" + trimmed)
        }
        if trimmed.contains(".") {
            return URL(string: "https://" + trimmed)
        }
        return URL(string: "http://" + trimmed)
    }

    // MARK: - Presenting

    private func presentAlert(title: String, message: String, actions: [UIAlertAction]) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for action in actions {
            alert.addAction(action)
        }
        DispatchQueue.main.async {
            Self.topViewController()?.present(alert, animated: true)
        }
    }

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncAddress()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        report(error)
    }

    private func syncAddress() {
        guard let url = webView.url else { return }
        currentURL = url.absoluteString
        addressField = url.absoluteString
        pageTitle = webView.title ?? url.host ?? ""
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        errorMessage = error.localizedDescription
    }
}

// MARK: - WKUIDelegate

extension BrowserModel: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            load(url)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        presentAlert(
            title: pageTitle.isEmpty ? "Page" : pageTitle,
            message: message,
            actions: [UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }]
        )
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        presentAlert(
            title: pageTitle.isEmpty ? "Page" : pageTitle,
            message: message,
            actions: [
                UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) },
                UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) }
            ]
        )
    }
}
