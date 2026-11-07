//
//  RuntimeScanner.swift
//  PocketHost
//
//  Reads a page and works out which runtimes it depends on — module scripts,
//  classic scripts, stylesheets, WebAssembly, workers, fonts and images — so
//  those can be downloaded ahead of the first request instead of on demand.
//

import Foundation

enum RuntimeScanner {
    struct Dependency: Identifiable, Hashable {
        let path: String
        let kind: Kind

        var id: String { "\(kind.rawValue):\(path)" }

        enum Kind: String, Hashable {
            case script
            case module
            case style
            case wasm
            case worker
            case font
            case image
            case media
            case track
            case data

            var label: String {
                switch self {
                case .script: return "script"
                case .module: return "module"
                case .style: return "style"
                case .wasm: return "wasm"
                case .worker: return "worker"
                case .font: return "font"
                case .image: return "image"
                case .media: return "media"
                case .track: return "track"
                case .data: return "data"
                }
            }
        }
    }

    static func dependencies(inDocument html: String, documentPath: String) -> [Dependency] {
        var results: [Dependency] = []
        var seen: Set<String> = []

        func add(_ reference: String, kind: Dependency.Kind) {
            guard let path = resolve(reference, documentPath: documentPath) else { return }

            let key = "\(kind.rawValue):\(path)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            results.append(Dependency(path: path, kind: kind))
        }

        for reference in references(pattern: #"<script[^>]*\ssrc\s*=\s*["']([^"']+)"#, in: html) {
            let kind: Dependency.Kind = reference.lowercased().hasSuffix(".mjs") ? .module : .script
            add(reference, kind: kind)
        }

        for reference in references(pattern: #"<link[^>]*\shref\s*=\s*["']([^"']+)"#, in: html) {
            if let kind = kind(forExtension: reference) {
                add(reference, kind: kind)
            }
        }

        for reference in references(pattern: #"["']([^"']+\.wasm)(?:\?[^"']*)?["']"#, in: html) {
            add(reference, kind: .wasm)
        }

        for reference in references(pattern: #"new\s+Worker\s*\(\s*["']([^"']+)"#, in: html) {
            add(reference, kind: .worker)
        }

        for reference in references(pattern: #"import\s+(?:[^;"']*?\s+from\s+)?["']([^"']+)["']"#, in: html) {
            add(reference, kind: .module)
        }

        // Media elements: what a player streams its picture, sound and text from.
        for reference in references(pattern: #"<source[^>]*\ssrc\s*=\s*["']([^"']+)"#, in: html) {
            add(reference, kind: .media)
        }

        for reference in references(pattern: #"<audio[^>]*\ssrc\s*=\s*["']([^"']+)"#, in: html) {
            add(reference, kind: .media)
        }

        for reference in references(pattern: #"<track[^>]*\ssrc\s*=\s*["']([^"']+)"#, in: html) {
            add(reference, kind: .track)
        }

        for reference in references(pattern: #"<img[^>]*\ssrc\s*=\s*["']([^"']+)"#, in: html) {
            add(reference, kind: .image)
        }

        for reference in references(pattern: #"<video[^>]*\sposter\s*=\s*["']([^"']+)"#, in: html) {
            add(reference, kind: .image)
        }

        return results
    }

    // MARK: - Resolution

    static func resolve(_ reference: String, documentPath: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let external = ["http://", "https://", "//", "data:", "javascript:", "mailto:", "tel:", "#", "?"]
        guard !external.contains(where: { lower.hasPrefix($0) }) else { return nil }

        let withoutQuery = trimmed
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed
        let withoutFragment = withoutQuery
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? withoutQuery
        guard !withoutFragment.isEmpty else { return nil }

        let combined: String
        if withoutFragment.hasPrefix("/") {
            combined = withoutFragment
        } else {
            let directory = (documentPath as NSString).deletingLastPathComponent
            let prefix = directory.isEmpty || directory == "/" ? "/" : directory + "/"
            combined = prefix + withoutFragment
        }

        return normalize(combined)
    }

    private static func normalize(_ path: String) -> String? {
        var stack: [String] = []

        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !stack.isEmpty { stack.removeLast() }
            default:
                stack.append(String(component))
            }
        }

        guard !stack.isEmpty else { return nil }
        return "/" + stack.joined(separator: "/")
    }

    /// A stylesheet pulls its own fonts, images and data files in through
    /// `url()`, so those get preloaded too.
    static func dependencies(inStylesheet css: String, stylesheetPath: String) -> [Dependency] {
        var results: [Dependency] = []
        var seen: Set<String> = []

        for reference in references(pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#, in: css) {
            guard let path = resolve(reference, documentPath: stylesheetPath) else { continue }
            guard let kind = kind(forExtension: path) else { continue }
            guard seen.insert(path).inserted else { continue }
            results.append(Dependency(path: path, kind: kind))
        }

        return results
    }

    static func kind(forExtension path: String) -> Dependency.Kind? {
        switch (path as NSString).pathExtension.lowercased() {
        case "css": return .style
        case "js": return .script
        case "mjs": return .module
        case "wasm": return .wasm
        case "woff", "woff2", "ttf", "otf", "eot": return .font
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "ico",
             "apng", "bmp", "tiff":
            return .image
        case "mp4", "m4v", "m4s", "webm", "mov", "mkv", "ts", "m2ts", "mts",
             "mp3", "m4a", "aac", "wav", "ogg", "oga", "flac", "opus", "ac3", "eac3":
            return .media
        case "vtt", "webvtt", "srt", "ass", "ssa", "sbv": return .track
        case "json", "m3u8", "mpd", "m3u", "webmanifest", "gltf": return .data
        default: return nil
        }
    }

    private static func references(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var values: [String] = []

        for match in regex.matches(in: text, options: [], range: range) {
            guard match.numberOfRanges > 1, let captured = Range(match.range(at: 1), in: text) else { continue }
            values.append(String(text[captured]))
        }

        return values
    }
}
