// 画 App 图标：一块屏幕，右边滑出一条侧栏，里面三张卡片（Agent / 最近复制 / 留存）。
// 用法：swift scripts/make-icon.swift assets  →  assets/AppIcon.icns、assets/icon-1024.png
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
let S: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a) }
func rr(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

func draw() -> NSImage {
    let img = NSImage(size: NSSize(width: S, height: S))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS 图标网格：824 的圆角方块居中
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = rr(body, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    rgb(24, 32, 46).setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()
    NSGradient(colors: [rgb(44, 58, 82), rgb(20, 27, 40)])!.draw(in: body, angle: -90)

    // 左边：正在用的窗口，淡淡的几行
    let win = NSRect(x: 168, y: 250, width: 330, height: 524)
    rgb(255, 255, 255, 0.07).setFill(); rr(win, 34).fill()
    for (i, w) in [210.0, 250.0, 170.0, 230.0, 120.0].enumerated() {
        rgb(255, 255, 255, 0.13).setFill()
        rr(NSRect(x: 208, y: 690 - CGFloat(i) * 62, width: w, height: 22), 11).fill()
    }

    // 右边：贴着边的侧栏
    let bar = NSRect(x: 548, y: 40, width: 520, height: 944)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -10, height: 0), blur: 40, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    rgb(248, 245, 238).setFill(); bar.fill()
    ctx.restoreGState()
    // 侧栏内沿的一道暖黄色
    rgb(242, 194, 79).setFill()
    NSRect(x: 548, y: 40, width: 20, height: 944).fill()

    // 三张卡片
    let cx: CGFloat = 612, cw: CGFloat = 256, ch: CGFloat = 170, gap: CGFloat = 34
    let top: CGFloat = 801
    for i in 0..<3 {
        let r = NSRect(x: cx, y: top - CGFloat(i + 1) * ch - CGFloat(i) * gap, width: cw, height: ch)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: NSColor.black.withAlphaComponent(0.12).cgColor)
        NSColor.white.setFill(); rr(r, 30).fill()
        ctx.restoreGState()
        let ink = rgb(36, 46, 64)
        switch i {
        case 0: // Agent：一个亮着的点 + 进展
            rgb(62, 158, 102).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 34, y: r.midY - 24, width: 48, height: 48)).fill()
            ink.withAlphaComponent(0.85).setFill(); rr(NSRect(x: r.minX + 106, y: r.midY + 6, width: 126, height: 24), 12).fill()
            ink.withAlphaComponent(0.30).setFill(); rr(NSRect(x: r.minX + 106, y: r.midY - 36, width: 86, height: 22), 11).fill()
        case 1: // 最近复制：几行字
            ink.withAlphaComponent(0.85).setFill(); rr(NSRect(x: r.minX + 34, y: r.midY + 28, width: 150, height: 24), 12).fill()
            ink.withAlphaComponent(0.30).setFill(); rr(NSRect(x: r.minX + 34, y: r.midY - 12, width: 200, height: 22), 11).fill()
            ink.withAlphaComponent(0.30).setFill(); rr(NSRect(x: r.minX + 34, y: r.midY - 50, width: 120, height: 22), 11).fill()
        default: // 留存：一把钥匙 + 打码的点
            let y = r.midY
            rgb(242, 194, 79).setFill()
            let ring = NSBezierPath(ovalIn: NSRect(x: r.minX + 30, y: y - 34, width: 68, height: 68))
            ring.append(NSBezierPath(ovalIn: NSRect(x: r.minX + 50, y: y - 14, width: 28, height: 28)).reversed)
            ring.fill()
            rr(NSRect(x: r.minX + 92, y: y - 9, width: 62, height: 18), 6).fill()
            rr(NSRect(x: r.minX + 128, y: y - 32, width: 16, height: 30), 5).fill()
            ink.withAlphaComponent(0.75).setFill()
            for k in 0..<3 { NSBezierPath(ovalIn: NSRect(x: r.minX + 172 + CGFloat(k) * 26, y: y - 9, width: 18, height: 18)).fill() }
        }
    }
    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let img = draw()
let fm = FileManager.default
let set = outDir + "/AppIcon.iconset"
try? fm.removeItem(atPath: set)
try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! png(img, px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
try! png(img, 1024).write(to: URL(fileURLWithPath: outDir + "/icon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", outDir + "/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: set)
print(p.terminationStatus == 0 ? "✓ \(outDir)/AppIcon.icns" : "✗ iconutil 失败")
