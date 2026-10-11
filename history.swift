// history.swift — P1 历史归因：SQLite 滚动采样 + 尖峰事件检测
// 库：~/Library/Application Support/Culprit/history.sqlite（WAL；采样保留 2 天、事件保留 7 天）
// 事件口径：整机 CPU ≥50% 连续 5 拍（15 秒）开事件，回落 <35% 连续 10 拍（30 秒）关；
//          热压力 ≥serious 连续 2 拍开，≤fair 连续 20 拍（1 分钟）关。
//          事件开启即落库（ts_end 空=进行中），每拍回写峰值/均值，关闭时补 ts_end；
//          应用退出时的进行中事件在下次启动按最后采样时间自动收尾。
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct EventRow {
    let id: Int64
    let kind: String        // "cpu" | "thermal"
    let start: Date
    let end: Date?          // nil = 进行中
    let peakCPU: Double
    let avgCPU: Double
    let peakThermal: Int32
}

struct EventContributor {
    let name: String
    let avgCPU: Double
    let peakCPU: Double
    let memMB: Double
}

final class HistoryStore {
    private var db: OpaquePointer?

    private static let cpuOpenThreshold = 50.0, cpuStopThreshold = 35.0
    private static let cpuOpenTicks = 5, cpuStopTicks = 10
    private static let thermalOpenTicks = 2, thermalStopTicks = 20
    private static let topRows = 8
    private static let keepSamples: TimeInterval = 2 * 86400
    private static let keepEvents: TimeInterval = 7 * 86400
    private static let tickSeconds = 3.0

    private struct OpenCpuEvent {
        let id: Int64
        let start: Date
        var sum: Double = 0
        var peak: Double = 0
        var peakThermal: Int32 = 0
        var ticks = 0
    }
    private var cpuHighStreak = 0, cpuLowStreak = 0
    private var cpuEvent: OpenCpuEvent?
    private var thermalHighStreak = 0, thermalLowStreak = 0
    private var thermalEventID: Int64?
    private var thermalEventStart: Date?
    private var thermalPeak: Int32 = 0

    private var lastPrune = Date()

    private var insSample: OpaquePointer?
    private var insEvent: OpaquePointer?
    private var updEventClose: OpaquePointer?
    private var updEventLive: OpaquePointer?
    private var qEvents: OpaquePointer?
    private var qContrib: OpaquePointer?
    private var pruneSamples: OpaquePointer?
    private var pruneEvents: OpaquePointer?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Culprit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rc = sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &db)
        guard rc == SQLITE_OK, db != nil else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS samples(
                ts REAL NOT NULL, cpu REAL NOT NULL, mem REAL NOT NULL, thermal INTEGER NOT NULL,
                rank INTEGER NOT NULL, pid INTEGER, name TEXT, cpu_pct REAL, mem_mb REAL, disk_bps REAL)
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts)")
        exec("""
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
                ts_start REAL NOT NULL, ts_end REAL,
                peak_cpu REAL NOT NULL, avg_cpu REAL NOT NULL, peak_thermal INTEGER NOT NULL)
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_events_start ON events(ts_start)")
        // 上次运行留下的"进行中"事件按最后采样时间收尾
        exec("UPDATE events SET ts_end = COALESCE((SELECT MAX(ts) FROM samples), ts_start) WHERE ts_end IS NULL")

        prepare(&insSample, "INSERT INTO samples VALUES(?,?,?,?,?,?,?,?,?,?)")
        prepare(&insEvent, "INSERT INTO events(kind,ts_start,ts_end,peak_cpu,avg_cpu,peak_thermal) VALUES(?,?,?,?,?,?)")
        prepare(&updEventClose, "UPDATE events SET ts_end=?, peak_cpu=?, avg_cpu=?, peak_thermal=? WHERE id=?")
        prepare(&updEventLive, "UPDATE events SET peak_cpu=?, avg_cpu=?, peak_thermal=? WHERE id=?")
        prepare(&qEvents, "SELECT id,kind,ts_start,ts_end,peak_cpu,avg_cpu,peak_thermal FROM events ORDER BY ts_start DESC LIMIT ?")
        prepare(&qContrib, """
            SELECT name, AVG(cpu_pct), MAX(cpu_pct), MAX(mem_mb) FROM samples
            WHERE ts >= ? AND ts <= ? AND rank > 0 AND cpu_pct IS NOT NULL AND name IS NOT NULL
            GROUP BY name ORDER BY AVG(cpu_pct) DESC LIMIT ?
            """)
        prepare(&pruneSamples, "DELETE FROM samples WHERE ts < ?")
        prepare(&pruneEvents, "DELETE FROM events WHERE ts_start < ?")
        pruneOld()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - 采样落库 + 检测（每个采样拍调用一次）

    func record(_ s: SystemSnapshot) {
        guard db != nil else { return }
        exec("BEGIN")
        bindSample(ts: s.timestamp.timeIntervalSince1970, cpu: s.cpuPercent, mem: s.memUsedGB,
                   thermal: Int32(s.thermal.rawValue), rank: 0, pid: nil, name: nil,
                   cpuPct: nil, memMB: nil, diskBps: nil)
        for (i, p) in s.procs.prefix(Self.topRows).enumerated() {
            bindSample(ts: s.timestamp.timeIntervalSince1970, cpu: s.cpuPercent, mem: s.memUsedGB,
                       thermal: Int32(s.thermal.rawValue), rank: Int32(i + 1), pid: p.pid, name: p.name,
                       cpuPct: p.cpuPercent, memMB: p.memMB, diskBps: p.diskBps)
        }
        exec("COMMIT")
        detect(s)
        if Date().timeIntervalSince(lastPrune) > 3600 { pruneOld() }
    }

    private func detect(_ s: SystemSnapshot) {
        let thermal = Int32(s.thermal.rawValue)

        if cpuEvent != nil {
            cpuEvent!.sum += s.cpuPercent
            cpuEvent!.ticks += 1
            cpuEvent!.peak = max(cpuEvent!.peak, s.cpuPercent)
            cpuEvent!.peakThermal = max(cpuEvent!.peakThermal, thermal)
            liveUpdateCpuEvent()
        }
        if s.cpuPercent >= Self.cpuOpenThreshold {
            cpuLowStreak = 0
            cpuHighStreak += 1
            if cpuEvent == nil && cpuHighStreak >= Self.cpuOpenTicks {
                let start = s.timestamp.addingTimeInterval(-Double(Self.cpuOpenTicks - 1) * Self.tickSeconds)
                let id = insertEventOpen(kind: "cpu", start: start, peak: s.cpuPercent,
                                         avg: s.cpuPercent, peakThermal: thermal)
                cpuEvent = OpenCpuEvent(id: id, start: start)
            }
        } else {
            cpuHighStreak = 0
            if cpuEvent != nil {
                if s.cpuPercent < Self.cpuStopThreshold {
                    cpuLowStreak += 1
                    if cpuLowStreak >= Self.cpuStopTicks {
                        let end = s.timestamp.addingTimeInterval(-Double(cpuLowStreak - 1) * Self.tickSeconds)
                        closeCpuEvent(end: end)
                    }
                } else {
                    cpuLowStreak = 0
                }
            }
        }

        if thermalEventID != nil {
            thermalPeak = max(thermalPeak, thermal)
            liveUpdateThermalEvent()
        }
        if thermal >= 2 {
            thermalLowStreak = 0
            thermalHighStreak += 1
            if thermalEventID == nil && thermalHighStreak >= Self.thermalOpenTicks {
                let start = s.timestamp.addingTimeInterval(-Double(Self.thermalOpenTicks - 1) * Self.tickSeconds)
                thermalEventID = insertEventOpen(kind: "thermal", start: start, peak: 0, avg: 0, peakThermal: thermal)
                thermalEventStart = start
                thermalPeak = thermal
            }
        } else if thermal <= 1 {
            thermalHighStreak = 0
            if thermalEventID != nil {
                thermalLowStreak += 1
                if thermalLowStreak >= Self.thermalStopTicks {
                    let end = s.timestamp.addingTimeInterval(-Double(thermalLowStreak - 1) * Self.tickSeconds)
                    updateEvent(id: thermalEventID!, end: end, peak: 0, avg: 0, peakThermal: thermalPeak)
                    thermalEventID = nil
                    thermalEventStart = nil
                }
            }
        } else {
            thermalLowStreak = 0
        }
    }

    // MARK: - 查询（菜单渲染用）

    func recentEvents(limit: Int32 = 5) -> [EventRow] {
        guard let st = qEvents else { return [] }
        sqlite3_reset(st)
        sqlite3_bind_int(st, 1, limit)
        var out: [EventRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let endTS = sqlite3_column_type(st, 3) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(st, 3)
            out.append(EventRow(id: sqlite3_column_int64(st, 0),
                                kind: text(st, 1),
                                start: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                                end: endTS.map { Date(timeIntervalSince1970: $0) },
                                peakCPU: sqlite3_column_double(st, 4),
                                avgCPU: sqlite3_column_double(st, 5),
                                peakThermal: Int32(sqlite3_column_int64(st, 6))))
        }
        return out
    }

    func eventContributors(start: Date, end: Date, limit: Int32 = 5) -> [EventContributor] {
        guard let st = qContrib else { return [] }
        sqlite3_reset(st)
        sqlite3_bind_double(st, 1, start.timeIntervalSince1970 - 1)
        sqlite3_bind_double(st, 2, end.timeIntervalSince1970 + 1)
        sqlite3_bind_int(st, 3, limit)
        var out: [EventContributor] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(EventContributor(name: text(st, 0),
                                        avgCPU: sqlite3_column_double(st, 1),
                                        peakCPU: sqlite3_column_double(st, 2),
                                        memMB: sqlite3_column_double(st, 3)))
        }
        return out
    }

    // MARK: - SQLite 基础

    private func insertEventOpen(kind: String, start: Date, peak: Double, avg: Double, peakThermal: Int32) -> Int64 {
        guard let st = insEvent, let db = db else { return 0 }
        sqlite3_reset(st)
        sqlite3_bind_text(st, 1, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(st, 2, start.timeIntervalSince1970)
        sqlite3_bind_null(st, 3)
        sqlite3_bind_double(st, 4, peak)
        sqlite3_bind_double(st, 5, avg)
        sqlite3_bind_int64(st, 6, Int64(peakThermal))
        sqlite3_step(st)
        return sqlite3_last_insert_rowid(db)
    }

    private func liveUpdateCpuEvent() {
        guard let e = cpuEvent else { return }
        updateEvent(id: e.id, end: nil, peak: e.peak, avg: e.sum / Double(max(e.ticks, 1)), peakThermal: e.peakThermal)
    }

    private func liveUpdateThermalEvent() {
        guard let id = thermalEventID else { return }
        updateEvent(id: id, end: nil, peak: 0, avg: 0, peakThermal: thermalPeak)
    }

    private func closeCpuEvent(end: Date) {
        guard let e = cpuEvent else { return }
        updateEvent(id: e.id, end: end, peak: e.peak, avg: e.sum / Double(max(e.ticks, 1)), peakThermal: e.peakThermal)
        cpuEvent = nil
    }

    private func updateEvent(id: Int64, end: Date?, peak: Double, avg: Double, peakThermal: Int32) {
        let st = end != nil ? updEventClose : updEventLive
        guard let st = st else { return }
        sqlite3_reset(st)
        if let end = end {
            sqlite3_bind_double(st, 1, end.timeIntervalSince1970)
            sqlite3_bind_double(st, 2, peak)
            sqlite3_bind_double(st, 3, avg)
            sqlite3_bind_int64(st, 4, Int64(peakThermal))
            sqlite3_bind_int64(st, 5, id)
        } else {
            sqlite3_bind_double(st, 1, peak)
            sqlite3_bind_double(st, 2, avg)
            sqlite3_bind_int64(st, 3, Int64(peakThermal))
            sqlite3_bind_int64(st, 4, id)
        }
        sqlite3_step(st)
    }

    private func bindSample(ts: Double, cpu: Double, mem: Double, thermal: Int32,
                            rank: Int32, pid: pid_t?, name: String?,
                            cpuPct: Double?, memMB: Double?, diskBps: Double?) {
        guard let st = insSample else { return }
        sqlite3_reset(st)
        sqlite3_bind_double(st, 1, ts)
        sqlite3_bind_double(st, 2, cpu)
        sqlite3_bind_double(st, 3, mem)
        sqlite3_bind_int64(st, 4, Int64(thermal))
        sqlite3_bind_int(st, 5, rank)
        if let pid = pid { sqlite3_bind_int64(st, 6, Int64(pid)) } else { sqlite3_bind_null(st, 6) }
        if let name = name { sqlite3_bind_text(st, 7, name, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, 7) }
        if let v = cpuPct { sqlite3_bind_double(st, 8, v) } else { sqlite3_bind_null(st, 8) }
        if let v = memMB { sqlite3_bind_double(st, 9, v) } else { sqlite3_bind_null(st, 9) }
        if let v = diskBps { sqlite3_bind_double(st, 10, v) } else { sqlite3_bind_null(st, 10) }
        sqlite3_step(st)
    }

    private func pruneOld() {
        lastPrune = Date()
        if let st = pruneSamples {
            sqlite3_reset(st)
            sqlite3_bind_double(st, 1, Date().addingTimeInterval(-Self.keepSamples).timeIntervalSince1970)
            sqlite3_step(st)
        }
        if let st = pruneEvents {
            sqlite3_reset(st)
            sqlite3_bind_double(st, 1, Date().addingTimeInterval(-Self.keepEvents).timeIntervalSince1970)
            sqlite3_step(st)
        }
        exec("PRAGMA wal_checkpoint(TRUNCATE)")   // 收缩 WAL，防库文件虚胖
    }

    private func text(_ st: OpaquePointer?, _ col: Int32) -> String {
        guard let p = sqlite3_column_text(st, col) else { return "" }
        return String(cString: UnsafeRawPointer(p).assumingMemoryBound(to: CChar.self))
    }

    private func prepare(_ stmt: inout OpaquePointer?, _ sql: String) {
        guard let db = db else { return }
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    }

    private func exec(_ sql: String) {
        guard let db = db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
