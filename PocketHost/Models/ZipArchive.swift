//
//  ZipArchive.swift
//  PocketHost
//
//  Unpacks a .zip dropped into the hosted folder. The container is read here —
//  central directory, local headers, stored and deflated entries — and the
//  deflate streams are inflated with the system Compression framework, so no
//  package is needed for it.
//

import Compression
import Foundation

enum ZipArchiveError: LocalizedError {
    case notAnArchive
    case zip64
    case corrupt
    case tooLarge
    case empty

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            return "That file is not a zip archive PocketHost can read."
        case .zip64:
            return "That archive is in the Zip64 format, which PocketHost cannot open yet."
        case .corrupt:
            return "The archive is damaged and could not be unpacked."
        case .tooLarge:
            return "The archive is larger than the 200 MB PocketHost unpacks."
        case .empty:
            return "The archive has no files in it."
        }
    }
}

enum ZipArchive {
    private struct Entry {
        let name: String
        let method: UInt16
        let compressed: Int
        let uncompressed: Int
        let localOffset: Int
    }

    private static let maximumArchiveBytes = 200 * 1024 * 1024
    private static let maximumEntries = 2_000
    private static let maximumEntryBytes = 50 * 1024 * 1024

    /// Unpacks `archive` into `directory` and returns how many files were
    /// written. A single folder wrapping the whole archive is stripped, so the
    /// destination holds the site itself rather than another copy of it.
    @discardableResult
    static func extract(_ archive: URL, into directory: URL) throws -> Int {
        guard let data = try? Data(contentsOf: archive), !data.isEmpty else {
            throw ZipArchiveError.notAnArchive
        }
        guard data.count <= maximumArchiveBytes else { throw ZipArchiveError.tooLarge }
        guard let end = endOfCentralDirectory(in: data) else { throw ZipArchiveError.notAnArchive }

        let total = Int(u16(data, end + 10))
        let offset = Int(u32(data, end + 16))

        guard total > 0, offset < data.count else { throw ZipArchiveError.empty }
        guard total <= maximumEntries else { throw ZipArchiveError.tooLarge }

        var entries: [Entry] = []
        var cursor = offset

        for _ in 0..<total {
            guard u32(data, cursor) == 0x0201_4b50 else { break }

            let flags = u16(data, cursor + 8)
            let method = u16(data, cursor + 10)
            let compressed = Int(u32(data, cursor + 20))
            let uncompressed = Int(u32(data, cursor + 24))
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let localOffset = Int(u32(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { throw ZipArchiveError.corrupt }

            let nameData = data[nameStart..<(nameStart + nameLength)]
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? ""

            cursor = nameStart + nameLength + extraLength + commentLength

            // Encrypted entries and folders are not files to write.
            guard flags & 0x1 == 0, !name.hasSuffix("/"), !name.isEmpty else { continue }
            guard let clean = sanitized(name) else { continue }
            guard uncompressed <= maximumEntryBytes, compressed <= maximumEntryBytes else { continue }

            entries.append(
                Entry(
                    name: clean,
                    method: method,
                    compressed: compressed,
                    uncompressed: uncompressed,
                    localOffset: localOffset
                )
            )
        }

        guard !entries.isEmpty else { throw ZipArchiveError.empty }

        let wrapper = commonRoot(entries.map { $0.name })
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        var written = 0

        for entry in entries {
            var path = entry.name
            if let wrapper, path.hasPrefix(wrapper + "/") {
                path = String(path.dropFirst(wrapper.count + 1))
            }
            guard !path.isEmpty else { continue }

            guard let payload = try contents(of: entry, in: data) else { continue }

            let fileURL = directory.appendingPathComponent(path).standardizedFileURL
            let base = directory.standardizedFileURL.path
            guard fileURL.path.hasPrefix(base + "/") else { continue }

            try? manager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard (try? payload.write(to: fileURL, options: .atomic)) != nil else { continue }
            written += 1
        }

        guard written > 0 else { throw ZipArchiveError.empty }
        return written
    }

    // MARK: - Entries

    private static func contents(of entry: Entry, in data: Data) throws -> Data? {
        let local = entry.localOffset
        guard u32(data, local) == 0x0403_4b50 else { return nil }

        let nameLength = Int(u16(data, local + 26))
        let extraLength = Int(u16(data, local + 28))
        let start = local + 30 + nameLength + extraLength

        guard start >= 0, start + entry.compressed <= data.count else { return nil }
        let compressed = data[start..<(start + entry.compressed)]

        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            return inflate(Data(compressed), expected: entry.uncompressed)
        default:
            return nil
        }
    }

    /// Apple's Compression framework expects raw DEFLATE, which is exactly what
    /// a zip stores for method 8.
    private static func inflate(_ data: Data, expected: Int) -> Data? {
        guard !data.isEmpty else { return Data() }

        var capacity = max(expected, 64 * 1024)

        while capacity <= 512 * 1024 * 1024 {
            var output = Data(count: capacity)

            let written = output.withUnsafeMutableBytes { destination -> Int in
                data.withUnsafeBytes { source -> Int in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }

                    return compression_decode_buffer(
                        destinationBase,
                        capacity,
                        sourceBase,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if written > 0 {
                output.removeSubrange(written..<output.count)
                return output
            }

            if expected == 0 { return Data() }
            capacity *= 2
        }

        return nil
    }

    // MARK: - Names

    private static func sanitized(_ raw: String) -> String? {
        let parts = raw
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }

        guard !parts.isEmpty else { return nil }
        guard !parts.contains("..") else { return nil }
        guard !parts.contains(where: { $0.hasPrefix(".") }) else { return nil }
        guard parts.first != "__MACOSX" else { return nil }

        return parts.joined(separator: "/")
    }

    private static func commonRoot(_ names: [String]) -> String? {
        guard let first = names.first,
              let root = first.split(separator: "/").first.map(String.init),
              !root.isEmpty
        else { return nil }

        guard names.allSatisfy({ $0 == root || $0.hasPrefix(root + "/") }) else { return nil }
        return root
    }

    // MARK: - Structure

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }

        let lowest = max(0, data.count - minimum - 65_535)
        var offset = data.count - minimum

        while offset >= lowest {
            if u32(data, offset) == 0x0605_4b50 { return offset }
            offset -= 1
        }

        return nil
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
