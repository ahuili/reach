import AppKit
import Carbon
import Combine
import SwiftUI
import ReachCore

/// 截图：按 ⌃⌥A 冻住屏幕 → 框选（点一下选整个窗口）→ 直接在选区上标注 → 回车复制 / ⌘↩ 贴回刚才的窗口 / 空格放进篮子 / 钉在屏幕上。
/// 和手边连在一起的几件事：截完先认字，密钥所在的位置自动打码；图里的网址、命令、报错一键拿走；截图进复制历史，按图里的字能搜。
final class ShotController {
    let model: AppModel
    let monitor: ClipboardMonitor
    var testMode = false
    var store: Store { model.store }

    private var panels: [ShotPanel] = []
    private var frozen: [FrozenScreen] = []
    private var windows: [ShotWindow] = []
    private var prevApp: NSRunningApplication?
    var session: ShotSession?
    var doc: ShotDoc?
    var canvas: ShotCanvas?
    private var bar: NSHostingView<ShotBar>?
    /// 「看懂」卡片，放在选区旁边
    var card: NSHostingView<ShotExplainCard>?
    var editingView: ShotView?
    var source: (name: String, bundle: String?)?
    private var annotateOnly = false
    private var pins: [PinWindow] = []
    private var barWatch: AnyCancellable?
    var cardWatch: AnyCancellable?
    private var busy = false

    init(model: AppModel, monitor: ClipboardMonitor) { self.model = model; self.monitor = monitor }

    var isOpen: Bool { !panels.isEmpty }

    // MARK: 开始

    func start() {
        guard !isOpen, !busy else { return }
        prevApp = NSWorkspace.shared.frontmostApplication
        if prevApp?.bundleIdentifier == Bundle.main.bundleIdentifier { prevApp = nil }
        model.hidePanel()
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let shots = try await ShotGrab.freeze()
                guard !shots.isEmpty else { self.model.toast("没拿到屏幕画面"); return }
                self.open(frozen: shots, windows: ShotGrab.windows())
            } catch {
                if ShotGrab.allowed { self.model.toast("截图失败：\(error.localizedDescription)") } else { self.askPermission() }
            }
        }
    }

    /// 还没有「屏幕录制」权限：第一次让系统自己问（顺带把手边登记进列表）；之后给一步步的引导
    private func askPermission() {
        let d = UserDefaults.standard
        if !d.bool(forKey: "shotAskedScreen") {
            d.set(true, forKey: "shotAskedScreen")
            if CGRequestScreenCaptureAccess() { return }
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "截图需要「屏幕录制」权限"
        a.informativeText = """
        1. 点「打开设置」，会打开 隐私与安全性 › 屏幕与系统录音。
        2. 在列表里找「手边」或「Reach」，打开开关。
        3. 列表里没有的话，点列表下面的「+」，选中访达里已经帮你选好的 Reach.app。
        4. 打开之后回来点「重启手边」。
        """
        a.addButton(withTitle: "打开设置")
        a.addButton(withTitle: "重启手边")
        a.addButton(withTitle: "取消")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        case .alertSecondButtonReturn: Self.relaunch()
        default: break
        }
    }

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// 给已有的一张图加标注
    func annotate(_ it: Item) {
        guard !isOpen, let f = it.imageFile, let d = store.loadImage(f), let img = NSImage(data: d)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        annotate(image: img, sourceName: it.sourceApp, bundle: it.sourceBundle)
    }

    func annotate(image img: CGImage, sourceName: String?, bundle: String?) {
        prevApp = NSWorkspace.shared.frontmostApplication
        if prevApp?.bundleIdentifier == Bundle.main.bundleIdentifier { prevApp = nil }
        model.hidePanel()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        annotateOnly = true
        frozen = []; windows = []
        let p = makePanel(screen: screen, frozen: nil)
        let vis = screen.visibleFrame.insetBy(dx: 80, dy: 90)
        let bs = screen.backingScaleFactor
        let natural = CGSize(width: CGFloat(img.width) / bs, height: CGFloat(img.height) / bs)
        let s = min(1, vis.width / natural.width, vis.height / natural.height)
        let size = CGSize(width: natural.width * s, height: natural.height * s)
        // 视图坐标左上原点
        let r = CGRect(x: (screen.frame.width - size.width) / 2, y: (screen.frame.height - size.height) / 2 - 20, width: size.width, height: size.height).integral
        source = (sourceName ?? "截图", bundle)
        activate()
        beginEditing(p.view, rect: r, image: img)
    }

    func pin(_ it: Item) {
        guard let f = it.imageFile, let d = store.loadImage(f), let img = NSImage(data: d)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main!
        let bs = screen.backingScaleFactor
        var size = CGSize(width: CGFloat(img.width) / bs, height: CGFloat(img.height) / bs)
        let maxW = screen.visibleFrame.width * 0.6
        if size.width > maxW { size = CGSize(width: maxW, height: size.height * maxW / size.width) }
        let m = NSEvent.mouseLocation
        addPin(img, frame: CGRect(x: m.x - size.width / 2, y: m.y - size.height / 2, width: size.width, height: size.height))
    }

    // MARK: 测试模式（不碰屏幕权限）：拿一张图当作冻住的屏幕

    func openFake(_ img: CGImage) {
        guard let screen = NSScreen.main else { return }
        prevApp = nil
        open(frozen: [FrozenScreen(screen: screen, image: img)], windows: [])
    }

    func fakeSelect(_ r: CGRect) {
        guard let v = panels.first?.view else { return }
        beginEditing(v, rect: r)
    }

    func debugState() -> [String: Any] {
        ["open": isOpen, "editing": doc != nil, "auto": doc?.autoCount ?? 0, "marks": doc?.marks.count ?? 0,
         "findings": (session?.findings ?? []).map(\.label), "lines": session?.lines ?? [], "reading": session?.reading ?? false,
         "trans": "\(session?.trans ?? .off)", "glosses": (doc?.glosses ?? []).map(\.text), "notice": session?.notice ?? "",
         "answer": session?.explain?.turns.last?.answer ?? "", "explainError": session?.explain?.error ?? "", "explainBusy": session?.explain?.busy ?? false,
         "sentImage": session?.explain?.sentImage ?? false]
    }

    func debugReselect(_ r: CGRect) {
        guard let v = editingView, let old = v.selection else { return }
        v.selection = r
        reselect(v, from: old, to: r)
    }

    func debugHint(_ h: String?) { session?.hint = h }

    func debugTool(_ t: String) { if let tool = ShotTool(rawValue: t) { session?.tool = tool; canvas?.tool = tool } }
    func debugMark(_ m: ShotMark) { doc?.add(m) }
    var debugPixel: CGFloat { canvas?.k ?? 2 }

    func snapshot(to path: String) -> Bool {
        guard let v = editingView ?? panels.first?.view else { return false }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: 遮罩

    private func open(frozen shots: [FrozenScreen], windows ws: [ShotWindow]) {
        annotateOnly = false
        frozen = shots; windows = ws
        for f in shots { _ = makePanel(screen: f.screen, frozen: f) }
        activate()
    }

    private func makePanel(screen: NSScreen, frozen f: FrozenScreen?) -> ShotPanel {
        var frame = screen.frame
        if testMode { frame.origin = CGPoint(x: -30000, y: -30000) }
        let p = ShotPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isOpaque = f != nil
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        let v = ShotView(frame: CGRect(origin: .zero, size: screen.frame.size), frozen: f, owner: self)
        v.screenFrame = screen.frame
        p.contentView = v
        p.view = v
        panels.append(p)
        p.orderFrontRegardless()
        return p
    }

    private func activate() {
        guard !testMode else { return }
        NSApp.activate(ignoringOtherApps: true)
        let target = panels.first { $0.view.screenFrame.contains(NSEvent.mouseLocation) } ?? panels.first
        target?.makeKey()
        target?.makeFirstResponder(target?.view)
    }

    func close(reactivate: Bool = true) {
        canvas?.cancelText()
        for p in panels { p.orderOut(nil); p.close() }
        panels = []; frozen = []; windows = []
        card?.removeFromSuperview(); card = nil; cardWatch = nil
        doc = nil; canvas = nil; bar = nil; session = nil; editingView = nil; barWatch = nil
        if reactivate, !testMode { prevApp?.activate() }
    }

    // MARK: 框选

    /// 鼠标下面的窗口（视图坐标）
    func windowRect(at p: CGPoint, in v: ShotView) -> CGRect? {
        let g = CGPoint(x: v.screenFrame.minX + p.x, y: v.screenFrame.maxY - p.y)
        guard let w = windows.first(where: { $0.rect.contains(g) }) else { return nil }
        let r = w.rect.intersection(v.screenFrame)
        return CGRect(x: r.minX - v.screenFrame.minX, y: v.screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func beginEditing(_ v: ShotView, rect: CGRect, image given: CGImage? = nil) {
        let r = rect.intersection(v.bounds).integral
        guard r.width >= 4, r.height >= 4 else { return }
        let img: CGImage
        if let given { img = given } else {
            guard let f = v.frozen, let c = ShotGrab.crop(f.image, CGRect(x: r.minX * f.scale, y: r.minY * f.scale, width: r.width * f.scale, height: r.height * f.scale)) else { return }
            img = c
            let g = CGPoint(x: v.screenFrame.minX + r.midX, y: v.screenFrame.maxY - r.midY)
            if let w = windows.first(where: { $0.rect.contains(g) }) { source = (w.app, w.bundle) }
            else { source = (prevApp?.localizedName ?? "截图", prevApp?.bundleIdentifier) }
        }
        for p in panels { p.view.dimOthers = p.view !== v }
        v.selection = r
        v.phase = .editing
        editingView = v
        let d = ShotDoc(image: img)
        let s = ShotSession()
        s.annotateOnly = annotateOnly
        s.target = prevApp?.localizedName ?? ""
        s.basket = model.basket.count
        s.redactOn = store.settings.shotRedact
        let c = ShotCanvas(frame: r, doc: d)
        c.tool = s.tool; c.color = s.color
        c.onChange = { [weak s, weak d] in s?.canUndo = d?.canUndo ?? false }
        v.addSubview(c)
        doc = d; canvas = c; session = s
        barWatch = s.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.placeBar(); self?.placeCard() } }
        let h = NSHostingView(rootView: ShotBar(s: s, act: { [weak self] a in self?.act(a) }))
        v.addSubview(h)
        bar = h
        placeBar()
        v.window?.makeFirstResponder(c)
        v.window?.invalidateCursorRects(for: v)
        v.needsDisplay = true
        // 认字：找密钥打码、挑出能直接拿走的东西
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let reading = ShotReading.read(img)
            let found = ShotText.findings(lines: reading.lines)
            DispatchQueue.main.async {
                guard let self, self.doc === d else { return }
                s.reading = false
                s.lines = reading.lines
                s.lineBoxes = reading.lineBoxes
                s.lineSecret = reading.lineSecret
                s.boxes = reading.secretBoxes
                s.findings = found
                if s.redactOn, !reading.secretBoxes.isEmpty { d.setAuto(reading.secretBoxes, on: true, pixel: c.k) }
                s.secrets = reading.secretBoxes.count
                s.canUndo = d.canUndo
                self.placeBar()
                if let p = s.pending { s.pending = nil; self.act(p) }
            }
        }
    }

    /// 工具栏放在选区下面；下面放不下放上面；都放不下放在选区里面靠下
    func placeBar() {
        guard let h = bar, let v = editingView else { return }
        let sz = h.fittingSize
        let sel = v.selection ?? .zero
        var x = sel.maxX - sz.width
        x = max(8, min(v.bounds.width - sz.width - 8, x))
        var y = sel.maxY + 10
        if y + sz.height > v.bounds.height - 8 { y = sel.minY - sz.height - 10 }
        if y < 8 { y = sel.maxY - sz.height - 10 }
        h.frame = CGRect(x: x, y: y, width: sz.width, height: sz.height)
    }

    /// 选区外面重新拖：还没画标注时直接开始新的框选
    var canRestart: Bool { !annotateOnly && (doc?.marks.allSatisfy(\.auto) ?? true) }

    /// 拖边角改了选区：按新选区重新截，已经画的标注跟着挪过去
    func reselect(_ v: ShotView, from old: CGRect, to rect: CGRect) {
        guard let f = v.frozen else { return }
        let manual = (doc?.marks ?? []).filter { !$0.auto }
        let dx = (old.minX - rect.minX) * f.scale, dy = (old.minY - rect.minY) * f.scale
        canvas?.cancelText(); canvas?.removeFromSuperview(); bar?.removeFromSuperview(); card?.removeFromSuperview()
        canvas = nil; bar = nil; card = nil; doc = nil; session = nil
        beginEditing(v, rect: rect)
        for var m in manual {
            m.rect = m.rect.offsetBy(dx: dx, dy: dy)
            m.points = m.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            doc?.add(m)
        }
        session?.canUndo = doc?.canUndo ?? false
    }

    var annotating: Bool { annotateOnly }

    func setEditingChrome(hidden: Bool) { canvas?.isHidden = hidden; bar?.isHidden = hidden }

    func backToSelecting() {
        guard !annotateOnly else { close(); return }
        canvas?.cancelText()
        canvas?.removeFromSuperview(); bar?.removeFromSuperview(); card?.removeFromSuperview()
        canvas = nil; bar = nil; card = nil; doc = nil; session = nil
        for p in panels { p.view.dimOthers = false; p.view.selection = nil; p.view.phase = .selecting; p.view.needsDisplay = true }
        editingView?.window?.makeFirstResponder(editingView)
        if let v = editingView { v.window?.invalidateCursorRects(for: v) }
        editingView = nil
    }

    // MARK: 键盘

    /// 返回 true 表示处理了
    func key(_ e: NSEvent, in v: ShotView) -> Bool {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        if e.keyCode == 53 {
            if session?.explain != nil { act(.explain) } else if v.phase == .editing { backToSelecting() } else { close() }
            return true
        }
        if v.phase == .selecting, e.keyCode == 36 || e.keyCode == 76 { beginEditing(v, rect: v.bounds); return true }
        guard v.phase == .editing, let s = session else { return false }
        switch e.keyCode {
        case 36, 76: act(cmd ? .paste : .copy); return true
        case 49: if !s.annotateOnly { act(.basket) }; return true
        default: break
        }
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if cmd {
            switch ch {
            case "z": act(shift ? .redo : .undo); return true
            case "c": act(.copy); return true
            default: return false
            }
        }
        if ch == "y" { act(.translate); return true }
        if ch == "k" { act(.explain); return true }
        if let t = ShotTool.allCases.first(where: { $0.key.lowercased() == ch }) { act(.tool(t)); return true }
        return false
    }

    // MARK: 动作

    enum Action { case tool(ShotTool), color(Int), undo, redo, clear, toggleRedact, copy, paste, basket, pin, cancel, take(ShotText.Finding),
                  translate, explain, ask(String), copyAnswer, keepAnswer }

    func act(_ a: Action) {
        guard let s = session, let d = doc, let c = canvas else { return }
        switch a {
        case .tool(let t): c.commitText(); s.tool = t; c.tool = t; c.window?.invalidateCursorRects(for: c)
        case .color(let i): s.colorIndex = i; c.color = s.color
        case .undo: c.cancelText(); d.undo(); s.canUndo = d.canUndo; s.redactOn = d.autoCount > 0 || (s.redactOn && s.secrets == 0)
        case .redo: d.redo(); s.canUndo = d.canUndo
        case .clear: d.clear(); s.canUndo = d.canUndo; s.redactOn = false
        case .toggleRedact:
            s.redactOn.toggle()
            d.setAuto(s.boxes, on: s.redactOn, pixel: c.k); s.canUndo = d.canUndo
        case .cancel: close()
        case .take(let f):
            if !testMode {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(f.value, forType: .string)
            }
            close()
            model.toast("已复制图里的\(f.label == "全部文字" ? "文字" : f.label)")
        case .copy, .paste, .basket, .pin: finish(a)
        case .translate: toggleTranslate()
        case .explain: toggleExplain()
        case .ask(let q): ask(q)
        case .copyAnswer: copyAnswer()
        case .keepAnswer: keepAnswer()
        }
    }

    private func finish(_ a: Action) {
        guard let d = doc, let c = canvas, let v = editingView, let s = session else { return }
        // 还在认字、又开着自动打码：等认完、打好码再出去，免得带着密钥的原图先被复制走
        if s.reading, s.redactOn { s.pending = a; return }
        c.commitText()
        let img = d.render()
        guard let png = ShotGrab.png(img), let item = save(png) else { model.toast("截图没存下来"); close(); return }
        let masked = d.autoCount
        let note = masked > 0 ? "，遮住了 \(masked) 处密钥" : ""
        switch a {
        case .copy:
            close()
            if !testMode {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                monitor.syncCount()
            }
            model.toast("截图已复制\(note)")
        case .paste:
            let withBasket = !model.basket.isEmpty
            if withBasket, !model.basket.contains(item.id) { model.basket.append(item.id) }
            close()
            // 等刚才的窗口回到前台再贴
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if withBasket { self.model.paster.pasteBasket() } else { self.model.paster.paste(item, mode: .smart) }
            }
        case .basket:
            if !model.basket.contains(item.id) { model.basket.append(item.id) }
            close()
            model.toast("放进篮子了（\(model.basket.count) 条）\(note)。再按 \(store.settings.shotKey.label) 截下一张，最后一张按 ⌘↩ 一起贴回去")
        case .pin:
            let sel = v.selection ?? .zero
            let frame = CGRect(x: v.screenFrame.minX + sel.minX, y: v.screenFrame.maxY - sel.maxY, width: sel.width, height: sel.height)
            close(reactivate: true)
            addPin(img, frame: frame)
        default: break
        }
    }

    /// 截图进复制历史：图里的字一起存下（密钥打了码的，字里也换成圆点）
    private func save(_ png: Data) -> Item? {
        guard let file = store.saveImage(png) else { return nil }
        var it = Item(kind: .clip, ctype: .image, text: "", imageFile: file, sourceApp: source?.name ?? "截图", sourceBundle: source?.bundle,
                      hash: store.vault.fingerprint(png))
        if let s = session, !s.reading {
            let text = s.lines.joined(separator: "\n")
            let masked = (doc?.autoCount ?? 0) > 0
            it.ocr = masked ? SecretDetector.mask(text) : text
            if s.secrets > 0, !masked { it.sensitive = true }
        }
        monitor.ingest(&it)
        return monitor.lastCapturedId.flatMap { store.items[$0] }
    }

    private func addPin(_ img: CGImage, frame f: CGRect) {
        var frame = f
        if testMode { frame.origin = CGPoint(x: -30000, y: -30000) }
        let w = PinWindow(image: img, frame: frame)
        w.onClose = { [weak self] p in self?.pins.removeAll { $0 === p } }
        w.onCopy = { [weak self] i in
            guard let png = ShotGrab.png(i) else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setData(png, forType: .png)
            self?.monitor.syncCount(); self?.model.toast("已复制")
        }
        pins.append(w)
        w.orderFrontRegardless()
    }
}

// MARK: 遮罩窗口

final class ShotPanel: NSPanel {
    var view: ShotView!
    override var canBecomeKey: Bool { true }

    /// 手边没有菜单栏，⌘V 这些到不了输入框：在「接着问」里打字时自己转过去
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command), !f.contains(.option), firstResponder is NSTextView,
           let sel = PanelController.editAction((e.charactersIgnoringModifiers ?? "").lowercased(), shift: f.contains(.shift)) {
            NSApp.sendAction(sel, to: nil, from: nil); return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

final class ShotView: NSView {
    enum Phase { case selecting, editing }
    let frozen: FrozenScreen?
    weak var owner: ShotController?
    var screenFrame: CGRect = .zero
    var phase: Phase = .selecting
    var selection: CGRect?
    var hover: CGRect?
    var dimOthers = false { didSet { needsDisplay = true } }
    private var start: CGPoint?
    private var tracking: NSTrackingArea?
    /// 正在拖的边：左、上、右、下
    private var grab: (l: Bool, t: Bool, r: Bool, b: Bool)?
    private var grabFrom: CGRect = .zero

    init(frame: CGRect, frozen: FrozenScreen?, owner: ShotController) {
        self.frozen = frozen; self.owner = owner
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        if phase == .selecting { addCursorRect(bounds, cursor: .crosshair); return }
        guard let r = selection, frozen != nil else { return }
        addCursorRect(bounds, cursor: owner?.canRestart == true ? .crosshair : .arrow)
        let k: CGFloat = 7
        addCursorRect(CGRect(x: r.minX - k, y: r.minY + k, width: k * 2, height: r.height - k * 2), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.maxX - k, y: r.minY + k, width: k * 2, height: r.height - k * 2), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: r.minX + k, y: r.minY - k, width: r.width - k * 2, height: k * 2), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: r.minX + k, y: r.maxY - k, width: r.width - k * 2, height: k * 2), cursor: .resizeUpDown)
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            addCursorRect(CGRect(x: c.x - k, y: c.y - k, width: k * 2, height: k * 2), cursor: .crosshair)
        }
    }

    /// 点在哪条边或哪个角上（选区外 9 点以内都算）
    private func edges(at p: CGPoint) -> (l: Bool, t: Bool, r: Bool, b: Bool)? {
        guard let r = selection, frozen != nil else { return nil }
        let k: CGFloat = 9
        guard r.insetBy(dx: -k, dy: -k).contains(p) else { return nil }
        let e = (l: abs(p.x - r.minX) <= k, t: abs(p.y - r.minY) <= k, r: abs(p.x - r.maxX) <= k, b: abs(p.y - r.maxY) <= k)
        return e.l || e.t || e.r || e.b ? e : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    static let amber = NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.20, alpha: 1)

    override func draw(_ dirty: NSRect) {
        if let f = frozen {
            NSImage(cgImage: f.image, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        let dim = NSColor.black.withAlphaComponent(frozen == nil ? 0.62 : (dimOthers ? 0.5 : 0.38))
        let hole = phase == .editing ? selection : (selection ?? hover)
        let path = NSBezierPath(rect: bounds)
        if let h = hole { path.append(NSBezierPath(rect: h)); path.windingRule = .evenOdd }
        dim.setFill(); path.fill()
        guard let r = hole else {
            if phase == .selecting, frozen != nil { drawHint() }
            return
        }
        // 编辑时：八个拖点，拖了能改大小
        if phase == .editing, frozen != nil, owner?.annotating == false {
            Self.amber.setFill()
            for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.midY),
                      CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                let d = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                NSColor.black.withAlphaComponent(0.4).setStroke()
                let o = NSBezierPath(ovalIn: d); o.fill(); o.lineWidth = 0.5; o.stroke()
            }
        }
        // 选区边框
        Self.amber.setStroke()
        let b = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); b.lineWidth = selection == nil ? 2 : 1.5; b.stroke()
        if phase == .selecting, selection == nil { Self.amber.withAlphaComponent(0.08).setFill(); r.fill() }
        // 尺寸
        let scale = frozen?.scale ?? 1
        let label = "\(Int(r.width * scale)) × \(Int(r.height * scale))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(calibratedRed: 0.25, green: 0.16, blue: 0.0, alpha: 1)]
        let sz = label.size(withAttributes: attrs)
        let pill = CGRect(x: r.minX, y: r.minY - sz.height - 10 < 4 ? r.minY + 6 : r.minY - sz.height - 10, width: sz.width + 14, height: sz.height + 6)
        if phase == .selecting || frozen != nil {
            Self.amber.setFill(); NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attrs)
        }
    }

    private func drawHint() {
        guard screenFrame.contains(NSEvent.mouseLocation) || owner?.testMode == true else { return }
        let s = "拖动框选 · 点一下选整个窗口 · Esc 取消" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let sz = s.size(withAttributes: attrs)
        let r = CGRect(x: bounds.midX - sz.width / 2 - 16, y: 60, width: sz.width + 32, height: sz.height + 14)
        NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        s.draw(at: CGPoint(x: r.minX + 16, y: r.minY + 7), withAttributes: attrs)
    }

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseMoved(with e: NSEvent) {
        guard phase == .selecting, start == nil else { return }
        hover = owner?.windowRect(at: local(e), in: self)
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        let p = local(e)
        if phase == .editing {
            if let g = edges(at: p) { grab = g; grabFrom = selection ?? .zero; owner?.setEditingChrome(hidden: true); return }
            // 选区外面拖：还没画东西就当重新框选
            guard owner?.canRestart == true else { return }
            owner?.backToSelecting()
        }
        guard phase == .selecting else { return }
        start = p; selection = nil
    }

    override func mouseDragged(with e: NSEvent) {
        if phase == .editing, let g = grab {
            let p = local(e)
            var r = grabFrom
            if g.l { r = CGRect(x: min(p.x, r.maxX - 8), y: r.minY, width: r.maxX - min(p.x, r.maxX - 8), height: r.height) }
            if g.r { r.size.width = max(8, p.x - r.minX) }
            if g.t { r = CGRect(x: r.minX, y: min(p.y, r.maxY - 8), width: r.width, height: r.maxY - min(p.y, r.maxY - 8)) }
            if g.b { r.size.height = max(8, p.y - r.minY) }
            selection = r.intersection(bounds)
            needsDisplay = true
            return
        }
        guard phase == .selecting, let s = start else { return }
        let p = local(e)
        selection = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if phase == .editing, grab != nil {
            grab = nil
            if let r = selection, r != grabFrom { owner?.reselect(self, from: grabFrom, to: r) } else { owner?.setEditingChrome(hidden: false) }
            window?.invalidateCursorRects(for: self)
            return
        }
        guard phase == .selecting, let s = start else { return }
        start = nil
        var r = selection ?? .zero
        if r.width < 4 || r.height < 4 { r = owner?.windowRect(at: s, in: self) ?? bounds }
        selection = r
        owner?.beginEditing(self, rect: r)
    }

    override func rightMouseDown(with e: NSEvent) { phase == .editing ? owner?.backToSelecting() : owner?.close() }

    override func keyDown(with e: NSEvent) {
        if owner?.key(e, in: self) != true { super.keyDown(with: e) }
    }
}

// MARK: 工具栏

final class ShotSession: ObservableObject {
    static let colors: [NSColor] = [
        NSColor(calibratedRed: 0.93, green: 0.23, blue: 0.21, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.70, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.18, green: 0.74, blue: 0.42, alpha: 1),
    ]
    @Published var tool: ShotTool = .arrow
    @Published var colorIndex = 0
    @Published var canUndo = false
    @Published var reading = true
    @Published var findings: [ShotText.Finding] = []
    @Published var secrets = 0
    @Published var redactOn = true
    /// 等认完字再做的动作（回车、⌘↩ 这些）
    @Published var pending: ShotController.Action?
    /// 鼠标停在哪个按钮上，就在下面一行说它是干什么的（系统的悬停提示会被遮罩盖住，只能自己画）
    @Published var hint: String?
    var lines: [String] = []
    var lineBoxes: [CGRect] = []
    var lineSecret: [Bool] = []
    var boxes: [CGRect] = []
    /// 原位翻译
    enum Trans: Equatable { case off, loading, on }
    @Published var trans: Trans = .off
    /// 上一次的译文（关掉再打开不用重新问）
    var glossCache: [ShotGloss]?
    /// 「看懂」卡片的内容
    @Published var explain: ShotExplain?
    /// 第二行临时显示的一句话（比如还没配 AI）
    @Published var notice: String?
    var annotateOnly = false
    var target = ""
    var basket = 0
    var color: NSColor { Self.colors[colorIndex] }
}

struct ShotBar: View {
    @ObservedObject var s: ShotSession
    let act: (ShotController.Action) -> Void

    private let ink = Color(red: 0.25, green: 0.16, blue: 0.0)
    private let amber = Color(red: 0.96, green: 0.70, blue: 0.20)

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(ShotTool.allCases) { t in
                    icon(t.icon, on: s.tool == t, help: "\(t.title)  \(t.key)\(t == .text ? " · 点一下直接打字" : t == .step ? " · 点一下放一个 1、2、3" : t == .mosaic ? " · 拖一块打上马赛克" : t == .mark ? " · 横着一划，按一行字高" : "")") { act(.tool(t)) }
                }
                sep
                ForEach(ShotSession.colors.indices, id: \.self) { i in
                    Button { act(.color(i)) } label: {
                        Circle().fill(Color(nsColor: ShotSession.colors[i])).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Color.white.opacity(s.colorIndex == i ? 0.95 : 0), lineWidth: 2).padding(-3))
                            .frame(width: 22, height: 30)
                    }.buttonStyle(.plain).onHover { hover($0, "颜色") }
                }
                sep
                icon("arrow.uturn.backward", on: false, help: "撤销  ⌘Z") { act(.undo) }.opacity(s.canUndo ? 1 : 0.35)
                sep
                icon("translate", on: s.trans != .off, help: s.trans == .loading ? "翻译中…" : "原位翻译：译文直接盖在原文上，复制出去的图也是译好的。外文译成中文，中文译成英文  Y") { act(.translate) }
                icon("sparkles", on: s.explain != nil, help: "看懂：说清图里是什么——外文给译文和难词，报错给原因和下一步，图表给结论，还能接着问  K") { act(.explain) }
                sep
                icon("pin", on: false, help: "钉在屏幕上：截图浮在最上层，对着看。滚轮缩放，双击关掉") { act(.pin) }
                if !s.annotateOnly {
                    Button { act(.basket) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 13, weight: .medium))
                            if s.basket > 0 { Text("\(s.basket)").font(.system(size: 10, weight: .bold)).monospacedDigit() }
                        }.foregroundStyle(.white.opacity(0.85)).frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
                    }.buttonStyle(.plain).onHover { hover($0, "放进篮子：先存着，接着截下一张；最后一张按 ⌘↩ 一起贴  空格") }
                }
                sep
                icon("xmark", on: false, help: "不截了  右键或 Esc 重新框选") { act(.cancel) }
                if !s.target.isEmpty {
                    Button { act(.paste) } label: {
                        Text(s.basket > 0 ? "连同篮子贴回 ⌘↩" : "贴回\(shortName(s.target)) ⌘↩")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).onHover { hover($0, "直接贴进\(s.target)；终端里贴的是图片文件路径，Agent 能读") }
                }
                Button { act(.copy) } label: {
                    Text("复制 ↩").font(.system(size: 12, weight: .semibold)).foregroundStyle(ink)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(amber, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).padding(.leading, 4).onHover { hover($0, "复制到剪贴板，也存进手边的复制历史  ↩") }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(capsule)

            HStack(spacing: 6) {
                if let h = s.hint {
                    Text(h).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9)).padding(.horizontal, 6).frame(height: 24)
                } else if let n = s.notice {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(amber)
                    Text(n).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).padding(.trailing, 6).frame(height: 24)
                } else {
                    if s.trans == .loading {
                        ProgressView().controlSize(.mini).colorScheme(.dark)
                        Text("翻译中…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    }
                    if s.reading {
                        ProgressView().controlSize(.mini).colorScheme(.dark)
                        Text(s.pending == nil ? "认字中…" : "认完字、遮好密钥就好…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    }
                    if s.secrets > 0 {
                        chip(s.redactOn ? "lock.fill" : "lock.open", s.redactOn ? "已遮住 \(s.secrets) 处密钥" : "密钥没遮（\(s.secrets) 处）", strong: s.redactOn,
                             help: s.redactOn ? "截图里认出的 Key、密码已经打码；点一下取消" : "点一下把认出的密钥打码") { act(.toggleRedact) }
                    }
                    ForEach(s.findings, id: \.label) { f in
                        chip(f.icon, f.label == "全部文字" ? "复制全部文字" : "复制\(f.label)", strong: false, help: Self.preview(f.value)) { act(.take(f)) }
                    }
                    if !s.reading, s.secrets == 0, s.findings.isEmpty {
                        Text(s.annotateOnly ? "↩ 复制   ⌘↩ 贴回   Y 翻译   K 看懂   Esc 关掉" : "↩ 复制   ⌘↩ 贴回   Y 翻译   K 看懂   空格 放进篮子   Esc 重新框选")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).padding(.horizontal, 6).frame(height: 24)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(capsule)
        }
        .fixedSize()
        .padding(2)
    }

    private var capsule: some View {
        RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.12).opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var sep: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 18).padding(.horizontal, 4) }

    private func hover(_ inside: Bool, _ text: String) {
        if inside { s.hint = text } else if s.hint == text { s.hint = nil }
    }

    static func preview(_ v: String) -> String {
        let one = v.replacingOccurrences(of: "\n", with: " ")
        return "复制：" + (one.count > 60 ? String(one.prefix(60)) + "…" : one)
    }

    private func icon(_ name: String, on: Bool, help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: name).font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(on ? ink : .white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(on ? amber : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover($0, help) }
    }

    private func chip(_ icon: String, _ title: String, strong: Bool, help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(strong ? ink : .white.opacity(0.88))
            .padding(.horizontal, 9).frame(height: 24)
            .background(strong ? amber : Color.white.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain).help(help)
    }
}

/// 应用名太长就截一下
private func shortName(_ s: String) -> String { s.count > 8 ? String(s.prefix(7)) + "…" : s }
