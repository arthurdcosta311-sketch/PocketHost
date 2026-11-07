//
//  FileStore.swift
//  PocketHost
//
//  The files the server hands out. They live in Documents/www, which is also
//  visible in the Files app, so sites can be dropped in from a Mac or iCloud.
//

import Foundation

enum FileStoreError: LocalizedError {
    case invalidName
    case alreadyExists(String)
    case writeFailed
    case readFailed

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "That name cannot be used."
        case .alreadyExists(let name):
            return "\(name) already exists here."
        case .writeFailed:
            return "The file could not be saved."
        case .readFailed:
            return "The file could not be read as text."
        }
    }
}

final class FileStore: ObservableObject {
    let root: URL

    /// Bumped whenever something on disk changes, so views can refresh.
    @Published private(set) var version = 0

    struct Entry: Identifiable, Equatable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date

        var id: String { url.path }
        var fileExtension: String { url.pathExtension.lowercased() }

        var isHTML: Bool { ["html", "htm", "xhtml"].contains(fileExtension) }
        var isEditable: Bool { FileStore.editableExtensions.contains(fileExtension) }
        var isImage: Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "svg"].contains(fileExtension) }

        var sizeText: String {
            isDirectory ? "Folder" : FileStore.sizeText(size)
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.url == rhs.url
        }
    }

    static let editableExtensions: Set<String> = [
        "html", "htm", "xhtml", "css", "js", "mjs", "cjs", "json", "txt", "md",
        "svg", "xml", "csv", "yml", "yaml", "toml", "ts", "jsx", "tsx", "php",
        "py", "sh", "map", "webmanifest", "glsl", "frag", "vert", "sql"
    ]

    static let htmlTemplate = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>New page</title>
    <style>
      body {
        margin: 0; min-height: 100vh; display: grid; place-items: center;
        background: #060b13; color: #e8eef7;
        font: 400 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
      }
      main { text-align: center; padding: 24px; }
      h1 { font-size: 28px; letter-spacing: -0.02em; margin: 0 0 10px; }
      p { color: #8fa2b8; margin: 0; }
    </style>
    </head>
    <body>
    <main>
      <h1>It works.</h1>
      <p>Edit this file in PocketHost.</p>
    </main>
    </body>
    </html>
    """#

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        root = documents.appendingPathComponent("www", isDirectory: true)
    }

    // MARK: - Reading

    func contents(of directory: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [Entry] = []
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            entries.append(
                Entry(
                    url: url,
                    name: name,
                    isDirectory: values?.isDirectory ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func entry(for url: URL) -> Entry? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        guard values != nil else { return nil }
        return Entry(
            url: url,
            name: url.lastPathComponent,
            isDirectory: values?.isDirectory ?? false,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate ?? .distantPast
        )
    }

    func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count < 8_000_000 else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .isoLatin1)
    }

    func webPath(for url: URL) -> String {
        WebPath.path(for: url, in: root)
    }

    func totalFileCount() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory { count += 1 }
        }
        return count
    }

    // MARK: - Writing

    func write(text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw FileStoreError.writeFailed
        }
        bump()
    }

    func createFile(named name: String, in directory: URL, content: String = FileStore.htmlTemplate) throws -> URL {
        var clean = sanitize(name)
        guard !clean.isEmpty else { throw FileStoreError.invalidName }
        if !clean.contains(".") { clean += ".html" }

        let url = directory.appendingPathComponent(clean)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileStoreError.alreadyExists(clean)
        }
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            throw FileStoreError.writeFailed
        }
        bump()
        return url
    }

    func createFolder(named name: String, in directory: URL) throws {
        let clean = sanitize(name)
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw FileStoreError.invalidName }

        let url = directory.appendingPathComponent(clean, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileStoreError.alreadyExists(clean)
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FileStoreError.writeFailed
        }
        bump()
    }

    func rename(_ entry: Entry, to newName: String) throws {
        let clean = sanitize(newName)
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw FileStoreError.invalidName }
        guard !isRoot(entry.url) else { throw FileStoreError.invalidName }

        let destination = entry.url.deletingLastPathComponent().appendingPathComponent(clean)
        guard destination.standardizedFileURL != entry.url.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileStoreError.alreadyExists(clean)
        }
        do {
            try FileManager.default.moveItem(at: entry.url, to: destination)
        } catch {
            throw FileStoreError.writeFailed
        }
        bump()
    }

    func delete(_ entry: Entry) throws {
        guard !isRoot(entry.url) else { throw FileStoreError.invalidName }
        do {
            try FileManager.default.removeItem(at: entry.url)
        } catch {
            throw FileStoreError.writeFailed
        }
        bump()
    }

    /// Copies a file or a whole folder picked in the Files app into `directory`.
    func importItem(at source: URL, into directory: URL) throws {
        let destination = uniqueURL(for: source.lastPathComponent, in: directory)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw FileStoreError.writeFailed
        }
        bump()
    }

    // MARK: - Seeding

    @discardableResult
    func seedIfNeeded() -> Bool {
        ensureRoot()

        let marker = root.appendingPathComponent(".pockethost-seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return false }

        writeSamples(overwriting: false)
        try? Data().write(to: marker)
        bump()
        return true
    }

    func restoreSamples() {
        ensureRoot()
        writeSamples(overwriting: true)
        bump()
    }

    // MARK: - Helpers

    private func writeSamples(overwriting: Bool) {
        let manager = FileManager.default
        for sample in SampleSite.pages {
            let fileURL = root.appendingPathComponent(sample.path)
            let directory = fileURL.deletingLastPathComponent()

            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !overwriting, manager.fileExists(atPath: fileURL.path) { continue }
            try? sample.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func ensureRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func isRoot(_ url: URL) -> Bool {
        url.standardizedFileURL == root.standardizedFileURL
    }

    private func uniqueURL(for name: String, in directory: URL) -> URL {
        let base = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        let ext = base.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return trimmed.components(separatedBy: forbidden).joined()
    }

    private func bump() {
        version += 1
    }

    static func sizeText(_ bytes: Int64) -> String {
        if bytes == 0 { return "0 KB" }
        return sizeFormatter.string(fromByteCount: bytes)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
