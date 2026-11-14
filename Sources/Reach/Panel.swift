import AppKit
import Carbon
import SwiftUI
import ReachCore

/// 全局快捷键（Carbon），不需要辅助功能权限
enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var refs: [UInt32: EventHotKeyRef] = [:]

    @discardableResult
    static func register(id: UInt32, key: UInt32, mods: UInt32, _ h: @escaping () -> Void) -> Bool {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var hk = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { HotKey.handlers[hk.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(key, mods, EventHotKeyID(signature: OSType(0x4D52474E), id: id), GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let ref else { return false }
        handlers[id] = h
        refs[id] = ref
        return true
    }

    static func unregister(id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        handlers[id] = nil
    }
}

final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum ShowReason { case hotkey, edge, approval, menu }

final class PanelController: NSObject {
    let model: AppModel
    let panel: SidebarPanel
    private var monitors: [Any] = []
    private var reason: ShowReason = .hotkey
    private var edgeTimer: Timer?
    private var leaveTimer: Timer?
    private let width: CGFloat = 384
    let handles = EdgeHandles()
    var visible: Bool { panel.isVisible }
    var testMode = false

    init(model: AppModel) {
        self.model = model
        panel = SidebarPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
                             styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: SidebarView().environmentObject(model))
        let fx = NSVisualEffectView()
        fx.material = .sidebar
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: fx.leadingAnchor), host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
                                     host.topAnchor.constraint(equalTo: fx.topAnchor), host.bottomAnchor.constraint(equalTo: fx.bottomAnchor)])
        panel.contentView = fx
        installMonitors()
        handles.onOpen = { [weak self] in self?.show(.edge) }
        handles.onToggle = { [weak self] in
            guard let self else { return }
            if self.panel.isVisible { self.hide() } else { self.show(.menu) }
        }
        handles.onMoved = { [weak self] y in self?.model.settings.handleY = y }
    }

    /// 屏幕变了、设置变了都调一下
    func refreshHandles() {
        guard !testMode else { return }
        handles.rebuild(enabled: model.settings.edgeHandle, left: model.settings.edgeLeft, y: model.settings.handleY)
    }

    private func screenForMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func frame(on screen: NSScreen, shown: Bool) -> NSRect {
        let v = screen.visibleFrame
        let left = model.settings.edgeLeft
        if testMode { return NSRect(x: v.maxX + 3000, y: v.minY + 8, width: width, height: min(v.height - 16, 900)) }
        let x = left ? (shown ? v.minX + 8 : v.minX - width) : (shown ? v.maxX - width - 8 : v.maxX)
        return NSRect(x: x, y: v.minY + 8, width: width, height: v.height - 16)
    }

    func show(_ why: ShowReason) {
        // 记下当前在用的窗口：贴的时候贴给它
        if !testMode, let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != Bundle.main.bundleIdentifier,
           front.bundleIdentifier != "com.apple.loginwindow" {
            model.targetBundle = front.bundleIdentifier
            model.targetName = front.localizedName ?? ""
        }
        leaveTimer?.invalidate()
        if panel.isVisible {
            if why != .approval, why != .edge { panel.makeKey(); model.focusTick += 1 }
            if why == .hotkey || why == .menu { reason = why }
            return
        }
        reason = why
        if why != .approval { model.selection = nil }
        model.rebuild()
        let screen = screenForMouse()
        panel.setFrame(frame(on: screen, shown: false), display: false)
        panel.alphaValue = 0
        if why == .approval { panel.orderFrontRegardless() } else { panel.makeKeyAndOrderFront(nil); model.focusTick += 1 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame(on: screen, shown: true), display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        leaveTimer?.invalidate()
        panel.orderOut(nil)
        // 放回屏幕外，免得停在两块屏的交界处露出一条边
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        model.query = ""
        model.options = nil
        model.template = nil
        model.managingFolders = false
        model.confirmSecret = nil
        model.replyingTo = nil
    }

    func toggle() { if panel.isVisible && panel.isKeyWindow { hide() } else { show(.hotkey) } }

    private var pinned: Bool {
        model.editor != nil || model.saving != nil || model.template != nil || model.options != nil || model.managingFolders || !model.approvals.isEmpty || model.replyingTo != nil
            || !model.query.isEmpty || model.busy != nil
    }

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e) ? nil : e
        }) { monitors.append(m) }
        // 点到侧栏外面就收起
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, !self.testMode, self.panel.isVisible, self.model.editor == nil, !self.model.managingFolders, self.model.approvals.isEmpty else { return }
            self.hide()
        }) { monitors.append(m) }
        let move: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: move) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { move($0); return $0 }) { monitors.append(m) }
    }

    private func atEdge(_ p: NSPoint) -> Bool {
        guard let s = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return false }
        // 屏幕上下各留 15% 不触发，避开四个角的系统热角
        let y0 = s.frame.minY + s.frame.height * 0.15, y1 = s.frame.maxY - s.frame.height * 0.15
        guard p.y > y0, p.y < y1 else { return false }
        return model.settings.edgeLeft ? p.x <= s.frame.minX + 1 : p.x >= s.frame.maxX - 2
    }

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if !panel.isVisible {
            guard !testMode, model.settings.hotEdge, atEdge(p), edgeTimer == nil, NSEvent.pressedMouseButtons == 0 else { return }
            edgeTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.edgeTimer = nil
                if self.atEdge(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 { self.show(.edge) }
            }
            return
        }
        // 鼠标甩出来的：鼠标离开一会儿自动收回
        guard reason == .edge, !pinned else { leaveTimer?.invalidate(); leaveTimer = nil; return }
        let inside = panel.frame.insetBy(dx: -60, dy: -40).contains(p)
        if inside { leaveTimer?.invalidate(); leaveTimer = nil }
        else if leaveTimer == nil {
            leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.leaveTimer = nil
                if !self.pinned, !self.panel.frame.insetBy(dx: -60, dy: -40).contains(NSEvent.mouseLocation) { self.hide() }
            }
        }
    }

    /// 返回 true 表示这个键被侧栏用掉了
    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift), opt = e.modifierFlags.contains(.option)
        let code = e.keyCode
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if code == 53 { // Esc：一层一层退
            if model.editor != nil { model.editor = nil }
            else if model.saving != nil { model.saving = nil }
            else if model.managingFolders { model.managingFolders = false }
            else if model.template != nil { model.template = nil }
            else if model.options != nil { model.options = nil }
            else if model.replyingTo != nil { model.replyingTo = nil; model.focusTick += 1 }
            else if model.confirmSecret != nil { model.confirmSecret = nil }
            else if !model.query.isEmpty { model.query = "" }
            else if !model.basket.isEmpty { model.basket = [] }
            else { hide() }
            return true
        }
        // 手边没有菜单栏（侧栏 App），⌘V 这些编辑键不会自己走到输入框，这里直接转给它
        let typing = model.editor != nil || model.template != nil || model.managingFolders || model.replyingTo != nil || model.saving != nil
        if cmd, !opt, panel.firstResponder is NSTextView, let sel = Self.editAction(chars, shift: shift),
           typing || ["v", "x", "z"].contains(chars) || (chars == "a" && !model.query.isEmpty) {
            NSApp.sendAction(sel, to: nil, from: nil)
            return true
        }
        if model.editor != nil {
            if cmd && (code == 36 || chars == "s") { model.saveEditor(); return true }
            return false
        }
        if model.managingFolders { return false }
        if let sv = model.saving {
            let n = model.saveChoices.count
            switch code {
            case 125: model.saving?.index = min(n - 1, sv.index + 1); return true
            case 126: model.saving?.index = max(0, sv.index - 1); return true
            case 36, 76: chooseSave(); return true
            default:
                if cmd && chars == "s" { chooseSave(); return true }
                return false
            }
        }
        if model.template != nil {
            if code == 36 || code == 76 { fillTemplate(); return true }
            return false
        }
        if model.replyingTo != nil { return false }
        if let opts = model.options {
            switch code {
            case 125: model.optionIndex = min(opts.count - 1, model.optionIndex + 1); return true
            case 126: model.optionIndex = max(0, model.optionIndex - 1); return true
            case 123: model.options = nil; return true
            case 36, 76: model.chooseOption(model.optionIndex); return true
            default:
                if cmd && chars == "c" { model.copyOption(model.optionIndex); return true }
                if cmd && chars == "r", let it = model.selectedItem {
                    if model.revealed.contains(it.id) { model.revealed.remove(it.id) } else { model.revealed.insert(it.id) }
                    model.options = model.paster.options(for: it)
                    return true
                }
                if let n = Int(chars), n >= 1, n <= opts.count { model.chooseOption(n - 1); return true }
                return true
            }
        }
        switch code {
        case 48 where !cmd: // Tab：最近 ⇄ 抽屉
            model.tab = model.tab == .recent ? .kept : .recent; return true
        case 49 where !cmd && model.query.isEmpty: // 空格：放进 / 拿出篮子
            if let it = model.selectedItem { model.toggleBasket(it) }
            return true
        case 125: model.move(1); return true
        case 126: model.move(-1); return true
        case 36, 76:
            if cmd { if !model.basket.isEmpty { model.paster.pasteBasket() }; return true }
            if opt, let it = model.selectedItem { model.paster.paste(it, mode: .login); return true }
            if model.query.hasPrefix(">") { return true }
            if let it = model.selectedItem { model.activate(it, plain: shift) }
            return true
        case 124:
            // 光标在搜索框末尾（或没在打字）时，→ 打开"怎么贴"
            if model.selectedItem != nil, model.query.isEmpty || atEndOfField() { model.openOptions(); return true }
            return false
        case 51 where cmd:
            if let it = model.selectedItem { model.remove(it) }
            return true
        default: break
        }
        guard cmd else { return false }
        switch chars {
        case "s": model.startSave(model.selectedItem); return true
        case "n": model.newNote(); return true
        case "e": if let it = model.selectedItem { model.edit(it) }; return true
        case "b": if let it = model.selectedItem { model.toggleBasket(it); model.move(1) }; return true
        case "r":
            if let it = model.selectedItem { if model.revealed.contains(it.id) { model.revealed.remove(it.id) } else { model.revealed.insert(it.id) } }
            return true
        case "c":
            if let it = model.selectedItem, let p = model.paster.payload(it, mode: .raw, target: .other) {
                Pasteboard.write(p); model.paster.monitor?.syncCount(); model.toast("已复制")
            }
            return true
        case ",": (NSApp.delegate as? AppDelegate)?.openSettings(); return true
        case "1": model.tab = .recent; return true
        case "2": model.tab = .kept; return true
        case "a":
            // ⌘A：当前列表全部放进篮子（输入框里有字时交给输入框）
            guard model.query.isEmpty else { return false }
            for id in model.selectable where !model.basket.contains(id) { model.basket.append(id) }
            return true
        default: return false
        }
    }

    private func chooseSave() {
        guard let sv = model.saving else { return }
        let cs = model.saveChoices
        guard cs.indices.contains(sv.index) else { return }
        model.finishSave(cs[sv.index])
    }

    static func editAction(_ c: String, shift: Bool) -> Selector? {
        switch c {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        default: return nil
        }
    }

    private func atEndOfField() -> Bool {
        guard let tv = panel.firstResponder as? NSTextView else { return true }
        return tv.selectedRange().location >= (tv.string as NSString).length
    }

    /// 把侧栏画成一张图（测试用，只含手边自己的界面）
    func snapshot(to path: String) -> Bool {
        guard let v = panel.contentView else { return false }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        v.bounds.fill()
        rep.draw(in: v.bounds)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let out = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? out.write(to: URL(fileURLWithPath: path))) != nil
    }

    func fillTemplate() {
        guard let t = model.template else { return }
        model.template = nil
        model.paster.paste(t.item, mode: .filled(Template.fill(t.item.text, values: t.values)))
    }
}

/// 屏幕右上角的一行提示，几秒后自己消失
final class Toast {
    private var panel: NSPanel?
    private var timer: Timer?

    func show(_ text: String) {
        timer?.invalidate()
        panel?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 320
        let size = label.sizeThatFits(NSSize(width: 320, height: 200))
        let w = min(360, size.width + 28), h = size.height + 20
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: v.maxX - w - 16, y: v.maxY - h - 16, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 10; fx.layer?.masksToBounds = true
        label.frame = NSRect(x: 14, y: 10, width: w - 28, height: size.height)
        fx.addSubview(label)
        p.contentView = fx
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: min(6, 2.2 + Double(text.count) / 18), repeats: false) { [weak self] _ in
            self?.panel?.orderOut(nil); self?.panel = nil
        }
    }
}

/// 屏幕边上的小把手：平时一条细细的，鼠标靠近变宽变亮。滑上去打开侧栏，点一下开关，上下拖可以挪位置。
/// 旁边紧挨着另一块屏、鼠标一甩就过去碰不到边缘时，靠它打开。
final class EdgeHandles {
    static let size = NSSize(width: 16, height: 76)
    private var panels: [NSPanel] = []
    var onOpen: () -> Void = {}
    var onToggle: () -> Void = {}
    var onMoved: (Double) -> Void = { _ in }
    private var pending: DispatchWorkItem?
    private var left = false, y = 0.5, enabled = true
    private var obs: NSObjectProtocol?

    init() {
        obs = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.rebuild(enabled: self.enabled, left: self.left, y: self.y)
        }
    }

    private func rect(_ s: NSScreen) -> NSRect {
        let v = s.visibleFrame, sz = Self.size
        let top = v.maxY - 40 - sz.height
        let yy = top - CGFloat(min(max(y, 0), 1)) * max(v.height - 80 - sz.height, 0)
        return NSRect(x: left ? s.frame.minX : s.frame.maxX - sz.width, y: yy, width: sz.width, height: sz.height)
    }

    func rebuild(enabled: Bool, left: Bool, y: Double) {
        self.enabled = enabled; self.left = left; self.y = y
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        guard enabled else { return }
        for s in NSScreen.screens {
            let r = rect(s)
            let p = NSPanel(contentRect: r, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let v = HandleView(frame: NSRect(origin: .zero, size: r.size))
            v.right = !left
            v.onEnter = { [weak self] in
                let w = DispatchWorkItem { self?.onOpen() }
                self?.pending = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
            }
            v.onExit = { [weak self] in self?.pending?.cancel() }
            v.onClick = { [weak self] in self?.pending?.cancel(); self?.onToggle() }
            v.onDrag = { [weak self, weak p] dy in
                guard let p, let sc = p.screen else { return }
                self?.pending?.cancel()
                let vf = sc.visibleFrame
                var f = p.frame
                f.origin.y = min(max(f.origin.y + dy, vf.minY + 40), vf.maxY - 40 - Self.size.height)
                p.setFrame(f, display: true)
            }
            v.onDrop = { [weak self, weak p] in
                guard let self, let p, let sc = p.screen else { return }
                let vf = sc.visibleFrame
                let span = max(vf.height - 80 - Self.size.height, 1)
                let ny = Double((vf.maxY - 40 - Self.size.height - p.frame.minY) / span)
                self.onMoved(min(max(ny, 0), 1))
                self.rebuild(enabled: self.enabled, left: self.left, y: min(max(ny, 0), 1))
            }
            p.contentView = v
            p.orderFrontRegardless()
            panels.append(p)
        }
    }
}

final class HandleView: NSView {
    var right = true
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDrop: () -> Void = {}
    private var hot = false { didSet { needsDisplay = true } }
    private var downY: CGFloat = 0
    private var moved = false
    private var dragging = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hot = true; onEnter() }
    override func mouseExited(with event: NSEvent) { hot = false; if !dragging { onExit() } }
    override func mouseDown(with event: NSEvent) { downY = NSEvent.mouseLocation.y; moved = false; dragging = true }
    override func mouseDragged(with event: NSEvent) {
        let y = NSEvent.mouseLocation.y
        if !moved && abs(y - downY) < 4 { return }
        moved = true
        onDrag(y - downY)
        downY = y
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        if moved { onDrop() } else { onClick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = hot ? 7 : 4
        let h = bounds.height - (hot ? 6 : 22)
        let x = right ? bounds.maxX - w - 2 : 2
        let r = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2)
        if hot {
            NSColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1).setFill()
        } else {
            NSColor.white.withAlphaComponent(0.6).setFill()
        }
        path.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); path.lineWidth = 0.5; path.stroke()
    }
}
