//
//  DisplayHints.swift
//  PocketHost
//
//  Two things every served page gets in its head: the Web Crypto shim and a
//  stylesheet that tells WebKit not to tone high dynamic range content down.
//

import Foundation

enum DisplayHints {
    /// WebKit 26 lets a page keep its HDR images and video at full range with
    /// `dynamic-range-limit`; without this some content is mapped to SDR first.
    /// Browsers that do not know the property ignore it.
    static let style = "<style>html { dynamic-range-limit: no-limit; }</style>"

    static func injected(into html: String) -> String {
        var document = WebCryptoShim.injected(into: html)

        guard !document.contains("dynamic-range-limit"),
              let close = document.range(of: "</head>", options: [.caseInsensitive])
        else { return document }

        let block = style + "\n    "
        return document.replacingCharacters(in: close.lowerBound..<close.lowerBound, with: block)
    }
}
