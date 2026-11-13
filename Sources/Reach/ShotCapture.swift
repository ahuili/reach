import AppKit
import ScreenCaptureKit
import Vision
import ReachCore

/// 一块屏幕在按下快捷键那一刻的画面（之后框选、标注都在这张冻住的图上做）
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
    /// 图片像素 / 屏幕点
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

/// 可以吸附的窗口，坐标是 Cocoa 全局坐标（左下原点）
struct ShotWindow {
    let rect: CGRect
    let app: String
    let bundle: String?
}

enum ShotGrab {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    /// 冻住所有屏幕。手边自己的窗口（侧栏、把手）不进画面
    static func freeze() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var out: [FrozenScreen] = []
        for d in content.displays {
            guard let screen = await MainActor.run(body: { NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID } }) else { continue }
            let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            let mode = CGDisplayCopyDisplayMode(d.displayID)
            cfg.width = mode?.pixelWidth ?? d.width * 2
            cfg.height = mode?.pixelHeight ?? d.height * 2
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            out.append(FrozenScreen(screen: screen, image: img))
        }
        return out
    }

    /// 屏幕上的普通窗口，从前到后
    static func windows() -> [ShotWindow] {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let pid = r[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  (r[kCGWindowLayer as String] as? Int) == 0,
                  let b = r[kCGWindowBounds as String] as? NSDictionary, let q = CGRect(dictionaryRepresentation: b),
                  q.width > 40, q.height > 40 else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            return ShotWindow(rect: CGRect(x: q.minX, y: primaryH - q.maxY, width: q.width, height: q.height),
                              app: r[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "", bundle: app?.bundleIdentifier)
        }
    }

    static func crop(_ img: CGImage, _ r: CGRect) -> CGImage? {
        img.cropping(to: r.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height)))
    }

    static func png(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }
}

/// 截图认字：每行字，以及密钥所在的位置（图片像素，左上原点）
struct ShotReading {
    var lines: [String] = []
    var secretBoxes: [CGRect] = []

    static func read(_ img: CGImage) -> ShotReading {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        var out = ShotReading()
        let W = CGFloat(img.width), H = CGFloat(img.height)
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first else { continue }
            out.lines.append(c.string)
            for ns in ShotText.secretRanges(in: c.string) {
                guard let r = Range(ns, in: c.string), let bb = try? c.boundingBox(for: r)?.boundingBox else { continue }
                let pad = max(3, bb.height * H * 0.18)
                out.secretBoxes.append(CGRect(x: bb.minX * W - pad, y: (1 - bb.maxY) * H - pad,
                                              width: bb.width * W + pad * 2, height: bb.height * H + pad * 2))
            }
        }
        return out
    }
}

// MARK: 钉在屏幕上

/// 截图钉在屏幕上：拖动移动，滚轮缩放，双击或 Esc 关掉，右键更多
final class PinWindow: NSPanel {
    private let image: CGImage
    private let base: CGSize
    var onClose: (PinWindow) -> Void = { _ in }
    var onCopy: (CGImage) -> Void = { _ in }

    init(image: CGImage, frame: CGRect) {
        self.image = image
        base = frame.size
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false // 由 ShotController 持有，关掉时自己放手
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = NSImageView(frame: CGRect(origin: .zero, size: frame.size))
        v.image = NSImage(cgImage: image, size: frame.size)
        v.imageScaling = .scaleProportionallyUpOrDown
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.masksToBounds = true
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.20, alpha: 0.9).cgColor
        contentView = v
    }

    override var canBecomeKey: Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { close(); return }
        super.mouseDown(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        let f = 1 + max(-0.3, min(0.3, e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.08)))
        var w = frame.width * f
        w = max(60, min(base.width * 4, w))
        let h = w * base.height / base.width
        let m = NSEvent.mouseLocation
        let rx = (m.x - frame.minX) / frame.width, ry = (m.y - frame.minY) / frame.height
        setFrame(CGRect(x: m.x - w * rx, y: m.y - h * ry, width: w, height: h), display: true)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { close() } else if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "c" { onCopy(image) } else { super.keyDown(with: e) }
    }

    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        m.addItem(withTitle: "复制图片", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: alphaValue < 1 ? "不透明" : "半透明", action: #selector(toggleAlpha), keyEquivalent: "").target = self
        m.addItem(withTitle: "原始大小", action: #selector(resetSize), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "关掉", action: #selector(closeIt), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(m, with: e, for: contentView!)
    }

    @objc private func copyImage() { onCopy(image) }
    @objc private func toggleAlpha() { alphaValue = alphaValue < 1 ? 1 : 0.55 }
    @objc private func resetSize() { setFrame(CGRect(origin: frame.origin, size: base), display: true) }
    @objc private func closeIt() { close() }
    override func close() { super.close(); onClose(self) }
}
