import AppKit

// 生成 Culprit 应用图标各尺寸 PNG（供 iconutil 打包 .icns）
// 图形：深红渐变圆角底 + 放大镜里的火焰（"追查发烧元凶"）
// 用法: swift make_icon.swift <输出目录 AppIcon.iconset>

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 背景：深红渐变 + 大圆角（macOS 图标风格，四周留 10% 边距）
let inset = size * 0.1
let radius = size * 0.185
let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
bg.addClip()
if let gradient = NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.26, alpha: 1),
                             ending: NSColor(calibratedRed: 0.55, green: 0.08, blue: 0.10, alpha: 1)) {
    gradient.draw(in: bg, angle: -90)
}

// 放大镜（镜框中心稍偏左上，右下留把手）
let cx = size * 0.46
let cy = size * 0.52
let lensR = size * 0.235

// 镜片内淡白罩光
let glass = NSBezierPath(ovalIn: NSRect(x: cx - lensR, y: cy - lensR, width: 2 * lensR, height: 2 * lensR))
NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.14).setFill()
glass.fill()

// 外焰（暖黄→橙渐变）：底部圆胖、顶端尖细右弯，右下带火舌内凹
let flame = NSBezierPath()
flame.move(to: NSPoint(x: cx - size * 0.13, y: cy - size * 0.135))                 // 左下（圆底起点）
flame.curve(to: NSPoint(x: cx + size * 0.115, y: cy - size * 0.095),
            controlPoint1: NSPoint(x: cx - size * 0.06, y: cy - size * 0.19),
            controlPoint2: NSPoint(x: cx + size * 0.07, y: cy - size * 0.185))     // 底部大圆弧
flame.curve(to: NSPoint(x: cx + size * 0.045, y: cy + size * 0.075),
            controlPoint1: NSPoint(x: cx + size * 0.165, y: cy - size * 0.03),
            controlPoint2: NSPoint(x: cx + size * 0.13, y: cy + size * 0.045))     // 右侧上升
flame.curve(to: NSPoint(x: cx - size * 0.015, y: cy + size * 0.205),
            controlPoint1: NSPoint(x: cx + size * 0.10, y: cy + size * 0.115),
            controlPoint2: NSPoint(x: cx + size * 0.02, y: cy + size * 0.16))      // 火舌内凹后翘出尖端
flame.curve(to: NSPoint(x: cx - size * 0.13, y: cy - size * 0.135),
            controlPoint1: NSPoint(x: cx - size * 0.075, y: cy + size * 0.13),
            controlPoint2: NSPoint(x: cx - size * 0.175, y: cy - size * 0.01))     // 尖端左侧下落回底
flame.close()
if let fg = NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.88, blue: 0.45, alpha: 1),
                       ending: NSColor(calibratedRed: 1.00, green: 0.52, blue: 0.18, alpha: 1)) {
    fg.draw(in: flame, angle: -90)
}

// 内焰（亮黄，顶尖圆底的小水滴）
let inner = NSBezierPath()
inner.move(to: NSPoint(x: cx, y: cy + size * 0.08))
inner.curve(to: NSPoint(x: cx + size * 0.065, y: cy - size * 0.09),
            controlPoint1: NSPoint(x: cx + size * 0.045, y: cy + size * 0.03),
            controlPoint2: NSPoint(x: cx + size * 0.07, y: cy - size * 0.035))
inner.curve(to: NSPoint(x: cx - size * 0.065, y: cy - size * 0.09),
            controlPoint1: NSPoint(x: cx + size * 0.03, y: cy - size * 0.165),
            controlPoint2: NSPoint(x: cx - size * 0.03, y: cy - size * 0.165))
inner.curve(to: NSPoint(x: cx, y: cy + size * 0.08),
            controlPoint1: NSPoint(x: cx - size * 0.07, y: cy - size * 0.035),
            controlPoint2: NSPoint(x: cx - size * 0.045, y: cy + size * 0.03))
inner.close()
NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.75, alpha: 0.95).setFill()
inner.fill()

// 镜框（白圈）与把手（右下 45°）
let ring = NSBezierPath(ovalIn: NSRect(x: cx - lensR, y: cy - lensR, width: 2 * lensR, height: 2 * lensR))
NSColor.white.setStroke()
ring.lineWidth = size * 0.048
ring.stroke()

let handle = NSBezierPath()
handle.lineWidth = size * 0.075
handle.lineCapStyle = .round
NSColor.white.setStroke()
let d = CGFloat(0.7071)
handle.move(to: NSPoint(x: cx + (lensR - size * 0.005) * d, y: cy - (lensR - size * 0.005) * d))
handle.line(to: NSPoint(x: cx + (lensR + size * 0.115) * d, y: cy - (lensR + size * 0.115) * d))
handle.stroke()

image.unlockFocus()

func writePNG(_ pixel: Int, _ name: String, _ dir: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixel, pixelsHigh: pixel,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixel, height: pixel))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: dir + "/" + name))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
writePNG(16, "icon_16x16.png", outDir)
writePNG(32, "icon_16x16@2x.png", outDir)
writePNG(32, "icon_32x32.png", outDir)
writePNG(64, "icon_32x32@2x.png", outDir)
writePNG(128, "icon_128x128.png", outDir)
writePNG(256, "icon_128x128@2x.png", outDir)
writePNG(256, "icon_256x256.png", outDir)
writePNG(512, "icon_256x256@2x.png", outDir)
writePNG(512, "icon_512x512.png", outDir)
writePNG(1024, "icon_512x512@2x.png", outDir)
print("iconset 已生成: \(outDir)")
