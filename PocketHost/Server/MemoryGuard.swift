//
//  MemoryGuard.swift
//  PocketHost
//
//  A 512 MB ceiling on anything the app is asked to hold in memory.
//
//  Files are streamed, so serving them is O(1) in memory; the guard exists to
//  catch the cases that are not: a single response large enough to blow the
//  process budget, which iOS answers by killing the app mid-request. Anything
//  over the ceiling is detected from its declared size before a byte is read,
//  so it can be refused (or deliberately streamed) and reported.
//

import Darwin
import Foundation

final class MemoryGuard {
    static let shared = MemoryGuard()

    /// The ceiling the app refuses to cross on its own.
    static let ceilingBytes: Int64 = 512 * 1024 * 1024

    struct Detection: Identifiable, Equatable {
        let id = UUID()
        let path: String
        let bytes: Int64
        let date: Date
        let refused: Bool
    }

    /// Off by default: over-size answers are detected, reported and streamed.
    /// Turning it on refuses them instead.
    var refusesOversized = false

    var onDetection: ((Detection) -> Void)?

    private let lock = NSLock()
    private var stored: [Detection] = []

    var detections: [Detection] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    var lastDetection: Detection? {
        detections.first
    }

    func allows(bytes: Int64) -> Bool {
        bytes <= Self.ceilingBytes
    }

    @discardableResult
    func report(path: String, bytes: Int64) -> Detection {
        let detection = Detection(
            path: path,
            bytes: bytes,
            date: Date(),
            refused: refusesOversized
        )

        lock.lock()
        stored.insert(detection, at: 0)
        if stored.count > 20 {
            stored.removeLast(stored.count - 20)
        }
        lock.unlock()

        let callback = onDetection
        DispatchQueue.main.async { callback?(detection) }

        return detection
    }

    func clearDetections() {
        lock.lock()
        stored.removeAll()
        lock.unlock()
    }

    /// The app's own physical footprint — the number iOS kills the process for.
    static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    static func footprintText() -> String {
        FileStore.sizeText(footprintBytes())
    }
}
