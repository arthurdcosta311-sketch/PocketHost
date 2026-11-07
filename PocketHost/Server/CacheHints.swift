//
//  CacheHints.swift
//  PocketHost
//
//  Turns the runtimes a page needs into preload hints. The hints travel with
//  the page, so the device that asked for it downloads those files at once and
//  keeps them in its own cache — none of it is held on this phone.
//

import Foundation

enum CacheHints {
    /// The markup for one dependency, matching how the browser will load it.
    static func hint(for dependency: RuntimeScanner.Dependency) -> String? {
        let href = escape(dependency.path)

        switch dependency.kind {
        case .script, .worker:
            return "<link rel=\"preload\" href=\"\(href)\" as=\"script\">"
        case .module:
            return "<link rel=\"modulepreload\" href=\"\(href)\">"
        case .style:
            return "<link rel=\"preload\" href=\"\(href)\" as=\"style\">"
        case .wasm, .data:
            return "<link rel=\"preload\" href=\"\(href)\" as=\"fetch\" crossorigin>"
        case .font:
            return "<link rel=\"preload\" href=\"\(href)\" as=\"font\" type=\"\(fontType(for: dependency.path))\" crossorigin>"
        case .image:
            return "<link rel=\"preload\" href=\"\(href)\" as=\"image\">"
        case .track:
            return "<link rel=\"preload\" href=\"\(href)\" as=\"track\">"
        case .media:
            // Media is streamed with byte ranges. Preloading it would pull the
            // whole file instead of letting the player ask for what it needs.
            return nil
        }
    }

    static func markup(for dependencies: [RuntimeScanner.Dependency]) -> String {
        let lines = dependencies.compactMap { hint(for: $0) }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n    ") + "\n"
    }

    /// Puts the hints at the end of the head, or at the top of the document
    /// when the page has no head to put them in.
    static func insert(_ markup: String, into document: String) -> String {
        guard !markup.isEmpty else { return document }

        let block = "    " + markup

        if let range = document.range(of: "</head>", options: [.caseInsensitive]) {
            return document.replacingCharacters(in: range, with: block + "</head>")
        }

        return block + document
    }

    private static func fontType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "eot": return "application/vnd.ms-fontobject"
        default: return "font/woff2"
        }
    }

    private static func escape(_ path: String) -> String {
        path
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
