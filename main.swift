// main.swift — Culprit：macOS 菜单栏"元凶"显示器
// P0：常驻 CPU 指示 + 点开看 Top 进程；P1 规划历史采样与尖峰归因。构建：bash build.sh
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sampler = Sampler()
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
            self.sampler.tick()
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
        if Date().timeIntervalSince(sampler.last.timestamp) > 1.5 { sampler.tick() }
        renderMenu(menu)
    }

    private func renderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = sampler.last
        let thermalText: String
        switch s.thermal {
        case .nominal: thermalText = "正常"
        case .fair: thermalText = "偏高"
        case .serious: thermalText = "严重 🔥"
        case .critical: thermalText = "危急 🔥"
        default: thermalText = "未知"
        }
        let header = String(format: "CPU %.0f%%    内存 %.1f / %.0f GB    热状态:%@",
                            s.cpuPercent, s.memUsedGB, s.memTotalGB, thermalText)
        menu.addItem(disabled(header, secondary: true))
        menu.addItem(.separator())
        menu.addItem(disabled("CPU 占用 Top 10（单核口径，同活动监视器）", secondary: true))

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
        menu.addItem(disabled(String(format: "每 %.0f 秒采样 · Culprit P0（历史归因开发中）", Self.interval), secondary: true))
        menu.addItem(NSMenuItem(title: "退出 Culprit",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private func disabled(_ title: String, secondary: Bool = false) -> NSMenuItem {
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
