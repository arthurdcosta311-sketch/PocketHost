//
//  ZipWriter.swift
//  PocketHost
//
//  Builds a zip archive in memory for the deploy endpoints that take one.
//  Entries are stored rather than deflated: the host compresses the upload on
//  its side, and a stored archive costs one pass and no compressor memory on a
//  phone that is already running a web server.
//

import Foundation

enum ZipWriter {
    private struct Written {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    /// `files` are paths relative to the site root, with forward slashes.
    static func archive(_ files: [(path: String, data: Data)]) -> Data {
        var output = Data()
        var written: [Written] = []
        let stamp = dosTimestamp(Date())

        for file in files {
            guard let nameData = file.path.data(using: .utf8), nameData.count < 0xFFFF else { continue }
            let crc = crc32(file.data)
            let size = UInt32(truncatingIfNeeded: file.data.count)
            let offset = UInt32(truncatingIfNeeded: output.count)

            output.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            output.append(uint16: 20)          // version needed
            output.append(uint16: 0x0800)      // UTF-8 names
            output.append(uint16: 0)           // stored
            output.append(uint16: stamp.time)
            output.append(uint16: stamp.date)
            output.append(uint32: crc)
            output.append(uint32: size)
            output.append(uint32: size)
            output.append(uint16: UInt16(nameData.count))
            output.append(uint16: 0)           // extra
            output.append(nameData)
            output.append(file.data)

            written.append(Written(name: nameData, crc: crc, size: size, offset: offset))
        }

        let directoryOffset = UInt32(truncatingIfNeeded: output.count)

        for file in written {
            output.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            output.append(uint16: 20)          // version made by
            output.append(uint16: 20)          // version needed
            output.append(uint16: 0x0800)
            output.append(uint16: 0)
            output.append(uint16: stamp.time)
            output.append(uint16: stamp.date)
            output.append(uint32: file.crc)
            output.append(uint32: file.size)
            output.append(uint32: file.size)
            output.append(uint16: UInt16(file.name.count))
            output.append(uint16: 0)           // extra
            output.append(uint16: 0)           // comment
            output.append(uint16: 0)           // disk
            output.append(uint16: 0)           // internal attributes
            output.append(uint32: 0o100644 << 16)
            output.append(uint32: file.offset)
            output.append(file.name)
        }

        let directorySize = UInt32(truncatingIfNeeded: output.count) - directoryOffset
        let count = UInt16(truncatingIfNeeded: written.count)

        output.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        output.append(uint16: 0)               // this disk
        output.append(uint16: 0)               // disk with the directory
        output.append(uint16: count)
        output.append(uint16: count)
        output.append(uint32: directorySize)
        output.append(uint32: directoryOffset)
        output.append(uint16: 0)               // comment length

        return output
    }

    // MARK: - Checksums and dates

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, min(2107, parts.year ?? 1980)) - 1980
        let month = parts.month ?? 1
        let day = parts.day ?? 1
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let second = (parts.second ?? 0) / 2

        let time = UInt16((hour << 11) | (minute << 5) | second)
        let stamp = UInt16((year << 9) | (month << 5) | day)
        return (time, stamp)
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
