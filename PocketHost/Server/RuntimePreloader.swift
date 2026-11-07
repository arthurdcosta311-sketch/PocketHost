//
//  RuntimePreloader.swift
//  PocketHost
//
//  Works out what a page needs and hands that list to the device that asked
//  for it as preload hints. The client downloads those files straight away and
//  stores them itself; nothing is copied or held on this phone.
//

import Foundation

final class RuntimePreloader {
    static let shared = RuntimePreloader()

    /// Documents larger than this are streamed untouched.
    static let maximumDocumentBytes: Int64 = 4 * 1024 * 1024

    /// Stylesheets bigger than this are not opened to look for their own URLs.
    private static let maximumStylesheetBytes = 1 * 1024 * 1024

    /// How many references one document may pull in, so a pathological page
    /// cannot make a scan run away.
    private static let maximumReferences = 200

    struct Summary: Identifiable, Equatable {
        let id = UUID()
        let documentPath: String
        let dependencies: [RuntimeScanner.Dependency]
        let bytes: Int64
        let missing: Int
        let date: Date
    }

    /// Detect a page's runtimes and tell the client to fetch them. When off,
    /// documents are served exactly as they are on disk.
    var isEnabled = true

    var onPreload: ((Summary) -> Void)?

    private var reported: Set<String> = []
    private let lock = NSLock()

    /// Reads a document, finds everything it depends on and returns it with
    /// preload hints in the head. Nil means "serve the file as it is on disk".
    func preparedDocument(at url: URL, documentPath: String, root: URL) -> Data? {
        guard isEnabled else { return nil }

        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              size > 0,
              Int64(size) <= Self.maximumDocumentBytes,
              let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        let references = RuntimeScanner.dependencies(inDocument: html, documentPath: documentPath)
        guard !references.isEmpty else { return nil }

        var queue = references
        var index = 0
        var seen: Set<String> = []
        var present: [RuntimeScanner.Dependency] = []
        var bytes: Int64 = 0
        var missing = 0

        let rootPath = root.standardizedFileURL.path

        while index < queue.count, present.count < Self.maximumReferences {
            let dependency = queue[index]
            index += 1

            guard seen.insert(dependency.path).inserted else { continue }

            let relative = String(dependency.path.dropFirst())
            let fileURL = root.appendingPathComponent(relative).standardizedFileURL
            guard fileURL.path.hasPrefix(rootPath + "/") else { continue }

            guard let attributes = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  let fileSize = attributes.fileSize,
                  attributes.isDirectory != true
            else {
                missing += 1
                continue
            }

            bytes += Int64(fileSize)
            present.append(dependency)

            // A stylesheet brings its own fonts and images along.
            if dependency.kind == .style,
               fileSize <= Self.maximumStylesheetBytes,
               let stylesheet = try? Data(contentsOf: fileURL),
               let css = String(data: stylesheet, encoding: .utf8) {
                queue.append(contentsOf: RuntimeScanner.dependencies(inStylesheet: css, stylesheetPath: dependency.path))
            }
        }

        guard !present.isEmpty else { return nil }

        report(
            documentPath: documentPath,
            modified: values.contentModificationDate ?? .distantPast,
            dependencies: present,
            bytes: bytes,
            missing: missing
        )

        let markup = CacheHints.markup(for: present)
        guard !markup.isEmpty,
              let rewritten = CacheHints.insert(markup, into: html).data(using: .utf8)
        else { return nil }

        return rewritten
    }

    func resetHistory() {
        lock.lock()
        reported.removeAll()
        lock.unlock()
    }

    // MARK: - Reporting

    private func report(
        documentPath: String,
        modified: Date,
        dependencies: [RuntimeScanner.Dependency],
        bytes: Int64,
        missing: Int
    ) {
        let stamp = "\(documentPath)|\(Int(modified.timeIntervalSince1970))"

        lock.lock()
        let isNew = reported.insert(stamp).inserted
        if reported.count > 500 { reported.removeAll() }
        lock.unlock()

        guard isNew else { return }

        let summary = Summary(
            documentPath: documentPath,
            dependencies: dependencies,
            bytes: bytes,
            missing: missing,
            date: Date()
        )

        DispatchQueue.main.async { [weak self] in
            self?.onPreload?(summary)
        }
    }
}
