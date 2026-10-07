// sampler.swift — 系统与进程采样（全部用户态 API，无需 root/权限；每轮毫秒级开销）
// 口径：每进程 CPU% = ΔCPU时间 / Δ墙钟 × 100（单核口径，同活动监视器，吃满 8 核 = 800%）
//       整机 CPU% = busy ticks / all ticks（0~100，同活动监视器底部负载图）
//       内存 = 物理足迹 phys_footprint
import Foundation

struct ProcRow {
    var pid: pid_t
    var name: String
    var cpuPercent: Double
    var memMB: Double
}

struct SystemSnapshot {
    var cpuPercent: Double = 0
    var memUsedGB: Double = 0
    var memTotalGB: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var procs: [ProcRow] = []   // 已按 CPU 降序
    var timestamp = Date()
}

final class Sampler {
    private(set) var last = SystemSnapshot()

    private var prevProcCPU: [pid_t: UInt64] = [:]
    private var prevDate: Date?
    private var prevCoreTicks: [UInt32] = []   // 平铺，每核 4 个：user sys idle nice

    func tick() {
        let now = Date()
        var snap = SystemSnapshot()
        snap.timestamp = now
        snap.cpuPercent = sampleTotalCPU()
        (snap.memUsedGB, snap.memTotalGB) = sampleMemory()
        snap.thermal = ProcessInfo.processInfo.thermalState
        snap.procs = sampleProcesses(interval: prevDate.map { now.timeIntervalSince($0) } ?? 0)
        prevDate = now
        last = snap
    }

    // MARK: - 整机 CPU

    private func sampleTotalCPU() -> Double {
        var cpuCount: natural_t = 0
        var ticks: processor_info_array_t? = nil
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &ticks, &count) == KERN_SUCCESS,
              let ptr = ticks else { return last.cpuPercent }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: ptr),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        let newTicks = (0..<Int(count)).map { raw[$0] }
        var busy = 0.0, total = 0.0
        if prevCoreTicks.count == newTicks.count {
            for c in 0..<(newTicks.count / 4) {
                let b = c * 4
                let dUser = newTicks[b] &- prevCoreTicks[b]
                let dSys  = newTicks[b + 1] &- prevCoreTicks[b + 1]
                let dIdle = newTicks[b + 2] &- prevCoreTicks[b + 2]
                let dNice = newTicks[b + 3] &- prevCoreTicks[b + 3]
                busy += Double(dUser &+ dSys &+ dNice)
                total += Double(dUser &+ dSys &+ dIdle &+ dNice)
            }
        }
        prevCoreTicks = newTicks
        return total > 0 ? busy / total * 100 : last.cpuPercent
    }

    // MARK: - 内存

    private func sampleMemory() -> (Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { sp in
            sp.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ip in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, ip, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (last.memUsedGB, last.memTotalGB) }
        let page = UInt64(vm_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (Double(used) / 1e9, Double(ProcessInfo.processInfo.physicalMemory) / 1e9)
    }

    // MARK: - 每进程

    private func sampleProcesses(interval: TimeInterval) -> [ProcRow] {
        var pids = [pid_t](repeating: 0, count: 4096)
        var n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        if n >= pids.count {
            pids = [pid_t](repeating: 0, count: n + 256)
            n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        }
        var rows: [ProcRow] = []
        var newPrev: [pid_t: UInt64] = [:]
        if n > 0 { newPrev.reserveCapacity(n) }
        for i in 0..<max(n, 0) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ru = rusage_info_v4()
            var rv: Int32 = -1
            withUnsafeMutableBytes(of: &ru) { raw in
                // rusage_info_t 在 Swift 里是 UnsafeMutableRawPointer（C 联合体的不透明导入）
                rv = proc_pid_rusage(pid, RUSAGE_INFO_V4,
                                     raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard rv == 0 else { continue }
            let cpuNS = ru.ri_user_time &+ ru.ri_system_time   // 纳秒，进程生命周期累计
            newPrev[pid] = cpuNS
            var cpuPct = 0.0
            if interval > 0.5, let prev = prevProcCPU[pid] {
                cpuPct = Double(cpuNS &- prev) / 1e9 / interval * 100
            }
            rows.append(ProcRow(pid: pid, name: processName(pid),
                                cpuPercent: cpuPct,
                                memMB: Double(ru.ri_phys_footprint) / 1_048_576))
        }
        prevProcCPU = newPrev
        return rows.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(MAXPATHLEN)) > 0 {
            let s = String(cString: buf)
            if let idx = s.lastIndex(of: "/") { return String(s[s.index(after: idx)...]) }
            return s
        }
        var nbuf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN))
        if proc_name(pid, &nbuf, UInt32(nbuf.count)) > 0 { return String(cString: nbuf) }
        return "pid \(pid)"
    }
}
