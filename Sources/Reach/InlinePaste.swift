import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import ReachCore

// 就地候选：长按 ⌘V，光标旁浮出一排候选，松开 ⌘ 贴高亮那条。还有「按顺序贴」：篮子里几条，每按一次 ⌘V 贴下一条。
// 按键判定在 ReachCore.HoldPaste（离线测过），这里接系统键盘事件、读光标、画候选条。

final class InlinePaster {
    let model: AppModel
    var store: Store { model.store }
    /// ↓ 展开：打开侧栏
    var openPanel: () -> Void = {}
    private var machine = HoldPaste()
    private var tap: CFMachPort?
    private var timer: DispatchWorkItem?
    private var generation = 0
    private var candidates: [InlineCandidate] = []
    private var strip: InlineStrip?
    /// 按顺序贴：还没贴的
    private(set) var sequence: [String] = []
    private var sequenceTotal = 0
    var testMode = false

    init(model: AppModel) { self.model = model }

    var running: Bool { tap != nil }

    // MARK: 键盘拦截

    /// 只拦 ⌘V；别的键在空闲时一律原样放过。需要辅助功能权限，没有就不装
    @discardableResult
    func start() -> Bool {
        guard tap == nil, Keys.trusted else { return tap != nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<InlinePaster>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        tap = nil
        abort()
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 系统嫌我们慢把拦截关了：重新打开，手上这次作废
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            abort()
            return pass
        }
        if e.getIntegerValueField(.eventSourceUserData) == Keys.marker { return pass }
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags
        let cmd = flags.contains(.maskCommand), shift = flags.contains(.maskShift)
        let other = flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let rep = e.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // 按顺序贴：每次 ⌘V 换成下一条
        if !sequence.isEmpty, machine.state == .idle {
            if type == .keyDown, code == 9, cmd, !other, !shift {
                if !rep { DispatchQueue.main.async { self.pasteNextInSequence() } }
                return nil
            }
            if type == .keyDown, code == 53 { DispatchQueue.main.async { self.endSequence(done: false) } }
            return pass
        }

        let key: HoldPaste.Key
        switch type {
        case .keyDown where code == 9:
            if machine.state == .idle {
                guard store.settings.holdPaste, cmd, !shift, !other, !rep, !IsSecureEventInputEnabled(),
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return pass }
            }
            key = .vDown(repeat: rep, shift: shift, cmd: cmd, otherMods: other)
        case .keyUp where code == 9: key = .vUp
        case .flagsChanged:
            guard !cmd else { return pass }
            key = .cmdUp
        case .keyDown:
            guard machine.state != .idle else { return pass }
            key = .other(code: code)
        default: return pass
        }
        let r = feed(key)
        return r ? nil : pass
    }

    /// 喂给状态机并执行它要做的事；返回是否吞掉
    @discardableResult
    private func feed(_ k: HoldPaste.Key) -> Bool {
        let (swallow, effects) = machine.handle(k)
        for ef in effects { DispatchQueue.main.async { self.run(ef) } }
        return swallow
    }

    private func run(_ ef: HoldPaste.Effect) {
        switch ef {
        case .startTimer:
            timer?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.feed(.timer) }
            timer = w
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.15, min(store.settings.holdDelay, 1)), execute: w)
        case .cancelTimer: timer?.cancel(); timer = nil
        case .postPaste: Keys.pasteKey()
        case .resolve: resolve()
        case .show: show()
        case .move(let i): strip?.state.index = i
        case .choose(let i): choose(i)
        case .cancel: hide()
        case .expand: hide(); openPanel()
        }
    }

    private func abort() {
        timer?.cancel(); timer = nil
        machine.reset()
        hide()
    }

    // MARK: 算候选

    private var caret: Caret?

    private func resolve() {
        generation += 1
        let gen = generation
        let app = NSWorkspace.shared.frontmostApplication
        let bundle = app?.bundleIdentifier, pid = app?.processIdentifier, name = app?.localizedName ?? ""
        let target = TargetKind.of(bundle: bundle)
        // 读光标走辅助功能，个别 App 会慢：放到后台，键盘拦截不等它
        DispatchQueue.global(qos: .userInteractive).async {
            let c = Caret.locate(pid: pid, target: target)
            DispatchQueue.main.async {
                guard gen == self.generation, self.machine.state == .resolving else { return }
                var cc = c
                cc.hints.append(name)
                self.caret = cc
                self.model.targetBundle = bundle
                self.model.targetName = name
                let ctx = InlineContext(field: cc.field, target: target, bundle: bundle, hints: cc.hints)
                self.candidates = InlineRank.rank(Array(self.store.items.values), folders: self.store.folders, ctx: ctx)
                self.feed(.ready(self.candidates.count))
            }
        }
    }

    /// 测试入口：不读光标，按给定的输入框种类算一遍并画出来
    func debugShow(field: InputField, target: TargetKind, bundle: String?, hints: [String], at p: CGPoint?) -> [InlineCandidate] {
        let ctx = InlineContext(field: field, target: target, bundle: bundle, hints: hints)
        candidates = InlineRank.rank(Array(store.items.values), folders: store.folders, ctx: ctx)
        let pt = p ?? NSEvent.mouseLocation
        caret = Caret(rect: CGRect(x: pt.x, y: pt.y - 18, width: 1, height: 18), how: "debug", field: field, hints: hints)
        if !candidates.isEmpty { show() }
        return candidates
    }

    func debugIndex(_ i: Int) { strip?.state.index = i }

    func debugKey(_ k: HoldPaste.Key) -> [String: Any] {
        _ = feed(k)
        return ["state": "\(machine.state)", "index": machine.index]
    }

    var debugState: [String: Any] {
        ["state": "\(machine.state)", "index": machine.index, "shown": strip?.panel.isVisible ?? false,
         "frame": strip.map { NSStringFromRect($0.panel.frame) } ?? "", "caret": caret?.how ?? "", "sequence": sequence.count]
    }

    /// 把候选条画成 PNG（测试用，毛玻璃画不出来，底色用纯色代替）
    func debugSnapshot(to path: String) -> Bool {
        guard let v = strip?.panel.contentView else { return false }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: 候选条

    private func show() {
        guard let c = caret, !candidates.isEmpty else { return }
        hide()
        let s = InlineStrip(model: model, candidates: candidates, caret: c.rect, onPick: { [weak self] i in
            self?.machine.reset(); self?.choose(i)
        })
        strip = s
        s.present(testMode: testMode)
    }

    private func hide() {
        strip?.close()
        strip = nil
    }

    private func choose(_ i: Int?) {
        let pick = i.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil }
        hide()
        guard let c = pick, let it = store.items[c.itemId] else { return }
        if testMode { model.lastInlinePick = c.itemId; return }
        // 等用户把 ⌘ 松干净再贴（松手那一下系统还在发修饰键事件）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            if let v = c.value { self.model.paster.paste(it, mode: .value(v, secret: c.secret)) }
            else { self.model.paster.paste(it, mode: .smart) }
        }
    }

    // MARK: 按顺序贴

    func startSequence(_ ids: [String]) {
        let ids = ids.filter { store.items[$0] != nil }
        guard !ids.isEmpty else { return }
        guard testMode || start() else {
            model.toast("按顺序贴需要辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能 里允许「手边」")
            Keys.promptTrust(); return
        }
        sequence = ids; sequenceTotal = ids.count
        model.basket = []
        model.sequenceLeft = ids.count
        model.hidePanel()
        model.toast("按顺序贴：每按一次 ⌘V 贴下一条，共 \(ids.count) 条。Esc 结束。")
    }

    func pasteNextInSequence() {
        guard !sequence.isEmpty else { return }
        let id = sequence.removeFirst()
        model.sequenceLeft = sequence.count
        if let it = store.items[id] {
            model.targetBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if testMode { model.lastInlinePick = id } else { model.paster.paste(it, mode: .smart) }
        }
        if sequence.isEmpty { endSequence(done: true) }
        else { model.toast("已贴 \(sequenceTotal - sequence.count)/\(sequenceTotal)，下一条：\(store.items[sequence[0]].map { Text.truncate($0.displayTitle, 24) } ?? "")") }
    }

    func endSequence(done: Bool) {
        let left = sequence.count
        sequence = []
        model.sequenceLeft = 0
        model.toast(done ? "按顺序贴完了，共 \(sequenceTotal) 条" : "按顺序贴已结束，还有 \(left) 条没贴")
        if !store.settings.holdPaste && !testMode { stop() }
    }
}

// MARK: 光标在哪、是什么输入框

struct Caret {
    /// 屏幕坐标（左下为原点）
    var rect: CGRect
    /// caret 精确到光标；field 输入框；mouse 鼠标旁
    var how: String
    var field: InputField
    var hints: [String]

    static func locate(pid: pid_t?, target: TargetKind) -> Caret {
        let mouse = NSEvent.mouseLocation
        var c = Caret(rect: CGRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 20), how: "mouse",
                      field: target == .terminal ? .terminal : (target == .chat || target == .ai ? .chat : .other), hints: [])
        guard let pid else { return c }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron（微信、飞书、VS Code、Slack）默认不开辅助功能树，打开它才读得到输入框
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute), let t: String = attr(w, kAXTitleAttribute), !t.isEmpty { c.hints.append(t) }
        guard let el: AXUIElement = attr(app, kAXFocusedUIElementAttribute) else { return c }
        AXUIElementSetMessagingTimeout(el, 0.25)
        let role: String? = attr(el, kAXRoleAttribute), sub: String? = attr(el, kAXSubroleAttribute)
        let texts = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", kAXHelpAttribute]
            .compactMap { (a: String) -> String? in attr(el, a) }
        c.field = InlineContext.field(role: role, subrole: sub, texts: texts, target: target)
        if let r = caretRect(el) { c.rect = r; c.how = "caret"; return c }
        if let p: CGPoint = point(el, kAXPositionAttribute), let s: CGSize = size(el, kAXSizeAttribute), s.height > 0, s.height < 320, s.width > 0 {
            let r = flip(CGRect(origin: p, size: s))
            if onScreen(r) { c.rect = CGRect(x: r.minX + 8, y: r.minY, width: 1, height: min(r.height, 24)); c.how = "field" }
        }
        return c
    }

    private static func caretRect(_ el: AXUIElement) -> CGRect? {
        var rv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rv) == .success, let v = rv,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        func bounds(_ r: CFRange) -> CGRect? {
            var r = r
            guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
                  let o = out, CFGetTypeID(o) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(o as! AXValue, .cgRect, &rect), rect.height > 2, rect.height < 200, rect.origin != .zero else { return nil }
            return rect
        }
        let loc = range.location + range.length
        if let r = bounds(CFRange(location: loc, length: 0)) { let f = flip(r); return onScreen(f) ? f : nil }
        // 有的 App 空范围给不出位置：取前一个字，光标在它右边
        if loc > 0, let r = bounds(CFRange(location: loc - 1, length: 1)) {
            let f = flip(CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height))
            return onScreen(f) ? f : nil
        }
        return nil
    }

    /// 辅助功能的坐标原点在主屏左上，换成 AppKit 的左下
    private static func flip(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private static func onScreen(_ r: CGRect) -> Bool {
        r.isUsable && NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.minX, y: r.midY)) }
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return CFGetTypeID(v) == AXUIElementGetTypeID() ? (v as! T) : nil }
        return v as? T
    }

    private static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        var v: CFTypeRef?, p = CGPoint.zero
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v, CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        var v: CFTypeRef?, s = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v, CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }
}

// MARK: 候选条窗口

final class InlineStripState: ObservableObject {
    @Published var index = 0
    @Published var appeared = false
    /// 尖角离左边多远
    @Published var arrowX: CGFloat = 24
    @Published var below = true
}

final class InlineStrip {
    let panel: NSPanel
    let state = InlineStripState()
    private let caret: CGRect

    init(model: AppModel, candidates: [InlineCandidate], caret: CGRect, onPick: @escaping (Int) -> Void) {
        self.caret = caret
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let thumbs = Dictionary(uniqueKeysWithValues: candidates.compactMap { c -> (String, NSImage)? in
            guard c.ctype == .image, let f = model.store.items[c.itemId]?.imageFile, let d = model.store.loadImage(f), let img = NSImage(data: d) else { return nil }
            return (c.itemId, img)
        })
        let host = NSHostingView(rootView: InlineStripView(candidates: candidates, thumbs: thumbs, state: state, onPick: onPick))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        place(size)
    }

    private func place(_ size: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: caret.minX, y: caret.midY)) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? .zero
        var x = caret.minX - 24
        var y = caret.minY - 6 - size.height
        var below = true
        if y < v.minY + 4 { y = caret.maxY + 6; below = false }        // 下面放不下就放到光标上面
        x = min(max(x, v.minX + 8), v.maxX - size.width - 8)
        state.below = below
        state.arrowX = min(max(caret.minX - x, 18), size.width - 18)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    func present(testMode: Bool) {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.12; panel.animator().alphaValue = 1 }
        withAnimation(.easeOut(duration: 0.14)) { state.appeared = true }
    }

    func close() { panel.orderOut(nil) }
}

struct InlineStripView: View {
    let candidates: [InlineCandidate]
    let thumbs: [String: NSImage]
    @ObservedObject var state: InlineStripState
    let onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.below { arrow(up: true) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(Array(candidates.enumerated()), id: \.offset) { i, c in
                        card(i, c).onTapGesture { onPick(i) }
                    }
                }
                Text("松开 ⌘ 贴  ·  V 下一个  ⇧V 上一个  ·  1–\(candidates.count) 直接选  ·  ↓ 搜索  ·  Esc 取消")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.horizontal, 6).lineLimit(1)
            }
            .padding(7)
            .background(StripGlass().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            if !state.below { arrow(up: false) }
        }
        .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
        .padding(16)
        .scaleEffect(state.appeared ? 1 : 0.94, anchor: state.below ? .top : .bottom)
        .fixedSize()
    }

    private func arrow(up: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: max(0, state.arrowX - 16 - 7))
            StripArrow(up: up).fill(.regularMaterial).frame(width: 14, height: 7)
            Spacer(minLength: 0)
        }
    }

    private func card(_ i: Int, _ c: InlineCandidate) -> some View {
        let on = i == state.index
        return HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if let img = thumbs[c.itemId] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 7).fill(on ? Palette.brandInk.opacity(0.14) : Color.primary.opacity(0.06)).frame(width: 30, height: 30)
                        .overlay(Image(systemName: Self.icon(c)).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? Palette.brandInk : .secondary))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 12, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true).foregroundStyle(on ? Palette.brandInk : .primary)
                Text(c.detail).font(.system(size: 10)).lineLimit(1).foregroundStyle(on ? Palette.brandInk.opacity(0.7) : .secondary)
            }
            .frame(width: 118, alignment: .leading)
            Spacer(minLength: 0)
            Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(on ? Palette.brandInk.opacity(0.7) : Color.secondary.opacity(0.6))
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(width: 196, height: 66, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Palette.brand : Color.clear))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.08), value: state.index)
    }

    static func icon(_ c: InlineCandidate) -> String {
        if c.secret { return "key" }
        switch c.ctype {
        case .link: return "link"
        case .command: return "terminal"
        case .code, .json: return "chevron.left.forwardslash.chevron.right"
        case .error: return "exclamationmark.triangle"
        case .table: return "tablecells"
        case .credential: return "person.badge.key"
        case .secret: return "key"
        case .image: return "photo"
        case .file: return "doc"
        case .email: return "envelope"
        case .phone: return "phone"
        case .path: return "folder"
        case .text: return "text.alignleft"
        }
    }
}

private struct StripArrow: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up { p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) }
        else { p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)) }
        p.closeSubpath()
        return p
    }
}

private struct StripGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover; v.blendingMode = .behindWindow; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
