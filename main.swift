// main.swift — Culprit：macOS 菜单栏"元凶"显示器
// P0：常驻 CPU 指示 + 点开看 Top 进程；P1 规划历史采样与尖峰归因。构建：bash build.sh
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sampler = Sampler()
    private let store = HistoryStore()
    private var timer: Timer?
    private static let interval: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let b = statusItem.button {
            b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }
        sampler.tick()
        renderIndicator()
        // 菜单跟踪期间 default-mode timer 不触发，数据新鲜度由 menuNeedsUpdate 兜底
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.sampleNow()
            self.renderIndicator()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    private func renderIndicator() {
        let cpu = sampler.last.cpuPercent
        let color: NSColor
        if cpu >= 80 { color = .systemRed }
        else if cpu >= 50 { color = .systemOrange }
        else { color = .labelColor }
        let s = NSMutableAttributedString(string: String(format: "%.0f%%", cpu), attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        ])
        if sampler.last.thermal == .serious || sampler.last.thermal == .critical {
            s.append(NSAttributedString(string: "🔥", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 2),
            ]))
        }
        statusItem.button?.attributedTitle = s
        statusItem.button?.toolTip = "Culprit — 每 3 秒采样一次"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if Date().timeIntervalSince(sampler.last.timestamp) > 1.5 { sampleNow() }
        renderMenu(menu)
    }

    private func sampleNow() {
        sampler.tick()
        store.record(sampler.last)
    }

    private func renderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = sampler.last
        let header = String(format: "CPU %.0f%%    内存 %.1f / %.0f GB    热状态:%@",
                            s.cpuPercent, s.memUsedGB, s.memTotalGB,
                            Self.thermalName(Int32(s.thermal.rawValue)))
        menu.addItem(Self.disabled(header, secondary: true))
        menu.addItem(.separator())

        menu.addItem(Self.disabled("最近尖峰事件（悬停看归因详情）", secondary: true))
        let events = store.recentEvents(limit: 5)
        if events.isEmpty {
            menu.addItem(Self.disabled("暂无（口径：CPU≥50% 持续 15 秒 / 热压力严重）", secondary: true))
        }
        for ev in events {
            let item = NSMenuItem(title: Self.eventTitle(ev), action: nil, keyEquivalent: "")
            item.submenu = Self.eventSubmenu(ev, store: store)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(Self.disabled("CPU 占用 Top 10（单核口径，同活动监视器）", secondary: true))
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for p in s.procs.prefix(10) {
            var name = p.name
            if name.count > 28 { name = "…" + name.suffix(27) }
            let row = String(format: "%6.1f%%  %7.0f MB  ", p.cpuPercent, p.memMB) + name
            let item = NSMenuItem(title: row, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: row, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Self.disabled("每 3 秒采样 · P1 历史归因已启用（保留 2 天）", secondary: true))
        menu.addItem(NSMenuItem(title: "退出 Culprit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    // MARK: - 事件展示

    private static func thermalName(_ raw: Int32) -> String {
        switch ProcessInfo.ThermalState(rawValue: Int(raw)) ?? .nominal {
        case .nominal: return "正常"
        case .fair: return "偏高"
        case .serious: return "严重 🔥"
        case .critical: return "危急 🔥"
        default: return "未知"
        }
    }

    private static func clockText(_ d: Date, forceDay: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = (forceDay && !Calendar.current.isDateInToday(d)) ? "M/d HH:mm" : "HH:mm"
        return f.string(from: d)
    }

    private static func eventTitle(_ e: EventRow) -> String {
        let time: String
        if let end = e.end {
            time = "\(clockText(e.start, forceDay: true))–\(clockText(end))"
        } else {
            time = "\(clockText(e.start)) 起 · 进行中"
        }
        if e.kind == "thermal" {
            return "🔥 \(time) 热事件（最高 \(thermalName(e.peakThermal))）"
        }
        return "⚡ \(time) CPU 峰值 \(Int(e.peakCPU.rounded()))%"
    }

    private static func eventSubmenu(_ e: EventRow, store: HistoryStore) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let end = e.end ?? Date()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let dur = max(Int(end.timeIntervalSince(e.start)), 0)
        let durText = dur >= 60 ? "\(dur / 60) 分 \(dur % 60) 秒" : "\(dur) 秒"
        m.addItem(disabled("\(f.string(from: e.start)) – \(f.string(from: end))（\(durText)）"))
        if e.kind == "cpu" {
            m.addItem(disabled(String(format: "整机 CPU 平均 %.0f%% · 峰值 %.0f%% · 热最高 %@",
                                      e.avgCPU, e.peakCPU, thermalName(e.peakThermal))))
        } else {
            m.addItem(disabled("热压力最高达 \(thermalName(e.peakThermal))"))
        }
        m.addItem(.separator())
        m.addItem(disabled("当时 CPU 占用 Top 5（单核口径：avg 时段均值 / peak 瞬时峰）", secondary: true))
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let contributors = store.eventContributors(start: e.start, end: end)
        if contributors.isEmpty {
            m.addItem(disabled("（该时段无进程采样）"))
        }
        for c in contributors {
            var name = c.name
            if name.count > 26 { name = "…" + name.suffix(25) }
            let row = String(format: "avg %5.1f%%  peak %5.1f%%  %@", c.avgCPU, c.peakCPU, name)
            let item = NSMenuItem(title: row, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: row, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ])
            item.isEnabled = false
            m.addItem(item)
        }
        return m
    }

    private static func disabled(_ title: String, secondary: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        item.isEnabled = false
        return item
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
