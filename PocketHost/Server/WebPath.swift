//
//  WebPath.swift
//  PocketHost
//
//  Conversion between files on disk and the paths the HTTP server exposes.
//

import Foundation

enum WebPath {
    /// Characters that are safe inside a single path component of a URL.
    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%\"'<>`{}|\\^[]")
        return set
    }()

    static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? component
    }

    /// The path a file is served at, always starting with a slash.
    static func path(for url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path

        if filePath == rootPath { return "/" }
        guard filePath.hasPrefix(rootPath + "/") else { return "/" }

        let relative = String(filePath.dropFirst(rootPath.count))
        let encoded = relative
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { encode(String($0)) }
            .joined(separator: "/")

        return encoded.hasPrefix("/") ? encoded : "/" + encoded
    }
}
