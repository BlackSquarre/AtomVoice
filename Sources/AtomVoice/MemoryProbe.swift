import Darwin
import Foundation

/// 进程驻留内存探针：用 task_vm_info 拿到 phys_footprint，等价于 Xcode "Memory" 标签里的数字。
/// 仅用于 debug 构建下的内存优化测量；release 构建里没有调用方。
/// (Resident memory probe. Uses task_vm_info.phys_footprint — same number Xcode shows as "Memory".
///  Debug-only measurement helper; release builds have no callers.)
enum MemoryProbe {
    /// 当前进程的 physical footprint，单位 MB（保留一位小数）。失败返回 0。
    static func currentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let mb = Double(info.phys_footprint) / 1024.0 / 1024.0
        return (mb * 10).rounded() / 10
    }

    /// 写一条带标签的内存快照到 DebugLog，便于在 ~/Library/Logs/AtomVoice/debug.log 里 grep。
    /// (Write a tagged memory snapshot to DebugLog, grep-friendly in the log file.)
    static func log(_ tag: String) {
        DebugLog.info("[MemoryProbe] \(tag) -> \(currentMB()) MB")
    }
}
