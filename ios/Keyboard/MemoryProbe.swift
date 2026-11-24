import Darwin

/// Reads this process's physical footprint, the number iOS compares with a keyboard
/// extension's memory limit. `phys_footprint` counts dirty and compressed pages and leaves out
/// clean file-backed pages, which is why a memory-mapped read-only file costs almost nothing.
enum MemoryProbe {
    /// The current footprint in megabytes (1,048,576 bytes), or 0 when the kernel call fails.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
