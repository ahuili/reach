import AppKit
import SwiftUI
import Combine

// MARK: 标注

enum ShotTool: String, CaseIterable, Identifiable {
    case rect, arrow, pen, text, step, mosaic, mark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rect: return "框"; case .arrow: return "箭头"; case .pen: return "画笔"; case .text: return "文字"
        case .step: return "序号"; case .mosaic: return "打码"; case .mark: return "荧光笔"
        }
    }
    var icon: String {
        switch self {
        case .rect: return "rectangle"; case .arrow: return "arrow.up.right"; case .pen: return "scribble"; case .text: return "character.cursor.ibeam"
        case .step: return "1.circle"; case .mosaic: return "checkerboard.rectangle"; case .mark: return "highlighter"
        }
    }
    /// 单键切换
    var key: String {
        switch self {
        case .rect: return "R"; case .arrow: return "A"; case .pen: return "P"; case .text: return "T"
        case .step: return "N"; case .mosaic: return "M"; case .mark: return "H"
        }
    }
}

/// 一笔标注。位置、线宽、字号都按图片像素算（左上原点）
struct ShotMark: Identifiable, Equatable {
    var id = UUID()
    var tool: ShotTool
    var rect: CGRect
    var points: [CGPoint] = []
    var text = ""
    var number = 0
    var color: NSColor
    var width: CGFloat
    /// 自动打码（截图里认出的密钥）
    var auto = false
}

final class ShotDoc: ObservableObject {
    let image: CGImage
    @Published private(set) var marks: [ShotMark] = []
    @Published private(set) var canUndo = false
    private var undos: [[ShotMark]] = []
    private var redos: [[ShotMark]] = []

    init(image: CGImage) { self.image = image }

    var autoCount: Int { marks.filter(\.auto).count }
    var nextNumber: Int { (marks.filter { $0.tool == .step }.map(\.number).max() ?? 0) + 1 }

    func add(_ m: ShotMark) { commit(marks + [m]) }
    func setAuto(_ boxes: [CGRect], on: Bool, pixel: CGFloat) {
        var next = marks.filter { !$0.auto }
        if on { next = boxes.map { ShotMark(tool: .mosaic, rect: $0, color: .black, width: max(8, 9 * pixel), auto: true) } + next }
        commit(next)
    }
    func clear() { commit([]) }
    func undo() { guard let p = undos.popLast() else { return }; redos.append(marks); marks = p; canUndo = !undos.isEmpty }
    func redo() { guard let n = redos.popLast() else { return }; undos.append(marks); marks = n; canUndo = true }
    private func commit(_ next: [ShotMark]) {
        guard next != marks else { return }
        undos.append(marks); redos = []; marks = next; canUndo = true
    }

    func render(extra: ShotMark? = nil) -> CGImage { ShotRender.render(image, marks + (extra.map { [$0] } ?? [])) }
}

enum ShotRender {
    static func render(_ img: CGImage, _ marks: [ShotMark]) -> CGImage {
        let W = img.width, H = img.height
        guard !marks.isEmpty, let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        let h = CGFloat(H)
        c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        func bl(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) }
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        // 打码先画（基于原图），其他标注画在上面
        for m in marks where m.tool == .mosaic {
            let r = m.rect.integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard r.width >= 2, r.height >= 2, let part = img.cropping(to: r) else { continue }
            let block = max(4, m.width)
            let sw = max(1, Int(r.width / block)), sh = max(1, Int(r.height / block))
            guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            small.interpolationQuality = .medium
            small.draw(part, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            guard let tiny = small.makeImage() else { continue }
            c.saveGState(); c.interpolationQuality = .none; c.draw(tiny, in: bl(r)); c.restoreGState()
        }
        for m in marks where m.tool != .mosaic {
            c.saveGState(); defer { c.restoreGState() }
            c.setStrokeColor(m.color.cgColor); c.setFillColor(m.color.cgColor)
            c.setLineWidth(m.width); c.setLineCap(.round); c.setLineJoin(.round)
            switch m.tool {
            case .rect:
                let r = bl(m.rect)
                c.addPath(CGPath(roundedRect: r, cornerWidth: min(m.width * 1.6, r.width / 2), cornerHeight: min(m.width * 1.6, r.height / 2), transform: nil))
                c.strokePath()
            case .mark:
                c.setBlendMode(.multiply)
                c.setFillColor(m.color.withAlphaComponent(0.45).cgColor)
                c.addPath(CGPath(roundedRect: bl(m.rect), cornerWidth: m.width, cornerHeight: m.width, transform: nil)); c.fillPath()
            case .pen:
                guard let f = m.points.first else { break }
                c.move(to: pt(f)); for p in m.points.dropFirst() { c.addLine(to: pt(p)) }; c.strokePath()
            case .arrow:
                guard m.points.count == 2 else { break }
                let a = pt(m.points[0]), b = pt(m.points[1])
                let ang = atan2(b.y - a.y, b.x - a.x), len = hypot(b.x - a.x, b.y - a.y)
                let head = min(len * 0.6, max(m.width * 4.5, 14))
                let neck = CGPoint(x: b.x - head * 0.8 * cos(ang), y: b.y - head * 0.8 * sin(ang))
                c.move(to: a); c.addLine(to: neck); c.strokePath()
                c.move(to: b)
                c.addLine(to: CGPoint(x: b.x - head * cos(ang - 0.42), y: b.y - head * sin(ang - 0.42)))
                c.addLine(to: CGPoint(x: b.x - head * cos(ang + 0.42), y: b.y - head * sin(ang + 0.42)))
                c.closePath(); c.fillPath()
            case .step:
                let r = bl(m.rect)
                c.setShadow(offset: CGSize(width: 0, height: -m.width * 0.3), blur: m.width, color: NSColor.black.withAlphaComponent(0.35).cgColor)
                c.fillEllipse(in: r)
                c.setShadow(offset: .zero, blur: 0, color: nil)
                c.setStrokeColor(NSColor.white.cgColor); c.setLineWidth(max(2, r.width * 0.07)); c.strokeEllipse(in: r.insetBy(dx: r.width * 0.035, dy: r.width * 0.035))
                let s = "\(m.number)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: r.height * 0.55, weight: .bold), .foregroundColor: NSColor.white]
                let sz = s.size(withAttributes: attrs)
                s.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
            case .text:
                let attrs = textAttrs(m)
                let r = bl(m.rect)
                (m.text as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: attrs)
            case .mosaic: break
            }
        }
        return c.makeImage() ?? img
    }

    /// 文字带一圈描边，放在什么底色上都看得清
    static func textAttrs(_ m: ShotMark) -> [NSAttributedString.Key: Any] {
        let light = (m.color.usingColorSpace(.sRGB)?.brightnessComponent ?? 0) > 0.7
        return [.font: NSFont.systemFont(ofSize: m.width, weight: .semibold), .foregroundColor: m.color,
                .strokeColor: light ? NSColor.black.withAlphaComponent(0.55) : NSColor.white, .strokeWidth: -4.0]
    }
}

// MARK: 画布

/// 盖在选区上的画布：画面 = 冻住的截图 + 标注。视图里的一个点 = 图片里 k 个像素
final class ShotCanvas: NSView, NSTextFieldDelegate {
    let doc: ShotDoc
    var tool: ShotTool = .arrow
    var color: NSColor = .systemRed
    var onChange: () -> Void = {}
    private var draft: ShotMark?
    private var start: CGPoint?
    private var editor: NSTextField?
    private var editorAt: CGPoint = .zero
    private var cache: CGImage?
    private var bag: AnyCancellable?

    init(frame: CGRect, doc: ShotDoc) {
        self.doc = doc
        super.init(frame: frame)
        bag = doc.$marks.sink { [weak self] _ in self?.cache = nil; DispatchQueue.main.async { self?.needsDisplay = true } }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var k: CGFloat { CGFloat(doc.image.width) / max(1, bounds.width) }
    private func px(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: max(0, min(bounds.width, p.x)) * k, y: max(0, min(bounds.height, p.y)) * k)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair) }

    override func draw(_ dirty: NSRect) {
        if cache == nil { cache = doc.render() }
        // 正在画的这一笔叠在已经渲染好的图上，不用每次把所有标注重画一遍
        let img = draft.map { ShotRender.render(cache!, [$0]) } ?? cache!
        NSImage(cgImage: img, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private var lineWidth: CGFloat { (tool == .mark ? 2 : 3) * k }

    override func mouseDown(with e: NSEvent) {
        commitText()
        let p = px(e)
        switch tool {
        case .text: beginText(at: convert(e.locationInWindow, from: nil)); return
        case .step:
            let d = 26 * k
            doc.add(ShotMark(tool: .step, rect: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d), number: doc.nextNumber, color: color, width: 3 * k))
            onChange(); return
        default: break
        }
        start = p
        draft = ShotMark(tool: tool, rect: CGRect(origin: p, size: .zero), points: [p], color: color, width: tool == .mosaic ? max(8, 9 * k) : lineWidth)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = start, var d = draft else { return }
        var p = px(e)
        if e.modifierFlags.contains(.shift) {
            if tool == .arrow { // 水平、垂直或 45°
                let a = atan2(p.y - s.y, p.x - s.x), snap = (a / (.pi / 4)).rounded() * (.pi / 4), l = hypot(p.x - s.x, p.y - s.y)
                p = CGPoint(x: s.x + l * cos(snap), y: s.y + l * sin(snap))
            } else if tool == .rect || tool == .mosaic || tool == .mark {
                let side = max(abs(p.x - s.x), abs(p.y - s.y))
                p = CGPoint(x: s.x + (p.x >= s.x ? side : -side), y: s.y + (p.y >= s.y ? side : -side))
            }
        }
        if tool == .pen { d.points.append(p) } else { d.points = [s, p] }
        d.rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        if tool == .mark, abs(p.y - s.y) < 6 * k { // 横着一划：按一行字的高度画荧光笔
            let lh = 18 * k
            d.rect = CGRect(x: min(s.x, p.x), y: s.y - lh / 2, width: abs(p.x - s.x), height: lh)
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        defer { draft = nil; start = nil; needsDisplay = true }
        guard let d = draft else { return }
        let big = d.tool == .pen ? d.points.count > 2 : (d.rect.width > 4 * k || d.rect.height > 4 * k) && (d.tool != .arrow || hypot(d.rect.width, d.rect.height) > 8 * k)
        guard big else { return }
        doc.add(d); onChange()
    }

    // 文字：在点下去的地方直接打字，回车或点别处写上去
    private func beginText(at p: CGPoint) {
        let f = NSTextField(frame: CGRect(x: p.x - 2, y: p.y - 13, width: max(60, bounds.width - p.x), height: 26))
        f.isBordered = false; f.drawsBackground = false; f.focusRingType = .none
        f.font = .systemFont(ofSize: 18, weight: .semibold); f.textColor = color
        f.placeholderString = "输入文字，回车完成"
        f.delegate = self
        f.cell?.wraps = false; f.cell?.isScrollable = true
        addSubview(f)
        window?.makeFirstResponder(f)
        editor = f; editorAt = p
    }

    var isEditingText: Bool { editor != nil }

    func commitText() {
        guard let f = editor else { return }
        editor = nil
        let s = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        f.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !s.isEmpty else { return }
        var m = ShotMark(tool: .text, rect: .zero, text: s, color: color, width: 18 * k)
        let size = (s as NSString).boundingRect(with: CGSize(width: 4000 * k, height: 4000 * k), options: [.usesLineFragmentOrigin], attributes: ShotRender.textAttrs(m)).size
        m.rect = CGRect(x: editorAt.x * k, y: (editorAt.y - 11) * k, width: ceil(size.width) + 4 * k, height: ceil(size.height) + 2 * k)
        doc.add(m); onChange()
    }

    func cancelText() { editor?.removeFromSuperview(); editor = nil; window?.makeFirstResponder(self) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }
}
