//
//  MemoryFootprint.swift
//  PocketHost
//
//  How much memory the app is using. A readout, not a limit: PocketHost puts
//  no ceiling on what it serves, and every file is streamed in chunks.
//

import Darwin
import Foundation

enum MemoryFootprint {
    /// The app's own physical footprint — the number iOS actually looks at.
    static func bytes() -> Int64 {
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

    static func text() -> String {
        FileStore.sizeText(bytes())
    }
}
