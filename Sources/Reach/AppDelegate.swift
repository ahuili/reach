import AppKit
import Carbon
import Combine
import SwiftUI
import ReachCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var model: AppModel!
    var panelController: PanelController!
    var monitor: ClipboardMonitor!
    var paster: Paster!
    var ambient: Ambient?
    var organizer: Organizer!
    var rail: AgentRail!
    var bridge: Bridge!
    var shot: ShotController!
    var links: LinkRouter!
    /// 手边还没准备好时收到的链接（被点链接拉起来的那一下）
    private var pendingLinks: [(URL, pid_t?)] = []
    let toast = Toast()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var purgeTimer: Timer?
    private(set) var hotkeyOK = false
    private(set) var hotkey2OK = false
    private(set) var shotHotkeyOK = false

    func applicationWillFinishLaunching(_ note: Notification) {
        // 链接分流：手边是默认浏览器时，点的链接从这里进来。要在启动完成前注册，才接得住把手边拉起来的那个链接
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let links { links.handle(url, sourcePID: pid) } else { pendingLinks.append((url, pid)) }
    }

    /// 双击 html 文件之类（手边登记成了能打开网页）：交给默认去处
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if u.isFileURL { links?.openFile(u) } else if let links { links.handle(u, sourcePID: nil) } else { pendingLinks.append((u, nil)) }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // 已经有一个在跑：让它把侧栏打开，自己退出
        // 开机时系统可能按新旧两条登录项各拉起一次：刚开机几分钟内的第二个实例悄悄退出，不弹侧栏
        if IPC.request(["cmd": "ping"], timeout: 1) != nil {
            if ProcessInfo.processInfo.systemUptime > 300 { _ = IPC.request(["cmd": "show"], timeout: 1) }
            NSApp.terminate(nil); return
        }
        let store: Store
        let migrated = ReachPaths.migrateLegacy()
        do { store = try Store(vault: try Vault.open(migrated: migrated)) } catch {
            let a = NSAlert()
            a.messageText = "手边打不开自己的数据"
            a.informativeText = "读不到数据库密钥（\(error)）。从旧版升级时，手边会把钥匙串里的密钥最后读一次、搬到数据目录；如果系统刚才问过是否允许，请选「允许」后重新打开。"
            a.runModal()
            NSApp.terminate(nil); return
        }
        model = AppModel(store: store)
        panelController = PanelController(model: model)
        monitor = ClipboardMonitor(model: model)
        paster = Paster(model: model)
        paster.monitor = monitor
        organizer = Organizer(model: model)
        rail = AgentRail(model: model)
        bridge = Bridge(model: model)
        if ProcessInfo.processInfo.environment["REACH_KEYFILE"] != "1" { ambient = Ambient(model: model, monitor: monitor) }
        shot = ShotController(model: model, monitor: monitor)
        links = LinkRouter(model: model)
        model.paster = paster
        model.shot = shot
        model.links = links
        model.organizer = organizer
        model.rail = rail
        model.hidePanel = { [weak self] in self?.panelController.hide() }
        model.toast = { [weak self] t in self?.toast.show(t) }
        model.importSideNotes = { [weak self] in self?.importSideNotes() }
        bridge.showPanel = { [weak self] in self?.panelController.show(.approval) }
        rail.onNeedsYou = { [weak self] in self?.panelController.show(.approval) }
        monitor.onCapture = { [weak self] it in
            if it.ctype == .image { self?.organizer.ocr(it) }
            self?.organizer.scheduleNaming()
        }
        model.$query.debounce(for: .milliseconds(120), scheduler: RunLoop.main).sink { [weak self] q in self?.organizer.semanticSearch(q) }.store(in: &bag)

        // 测试模式（REACH_KEYFILE=1，数据在临时目录）：不碰真实剪贴板、不抢快捷键、侧栏画在屏幕外
        let test = ProcessInfo.processInfo.environment["REACH_KEYFILE"] == "1"
        panelController.testMode = test
        shot.testMode = test
        bridge.shot = shot
        bridge.testMode = test
        bridge.monitor = monitor
        links.testMode = test
        links.start()
        for (u, pid) in pendingLinks { links.handle(u, sourcePID: pid) }
        pendingLinks = []
        store.purgeExpired()
        if !test { monitor.start() }
        panelController.refreshHandles()
        if store.settings.agentRail { rail.start() }
        if !bridge.start() { toast.show("手边的本机通信没起来，Agent 暂时连不上它。") }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            if (self?.model.store.purgeExpired() ?? 0) > 0 { self?.model.rebuild() }
        }

        if !test {
            applyHotkeys()
            if !hotkeyOK { toast.show("\(model.settings.panelKey.label) 被别的 App 占着（多半是 Paste）。先用 ⌃⌥V 叫出手边，或者在设置里换一个快捷键。") }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "手边")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !test, !store.items.values.contains(where: { $0.origin == .imported }), let url = SideNotesImporter.available {
            let n = SideNotesImporter.count(url)
            if n > 0 { model.sideNotesHint = n }
        }
        // 开机自动打开：以设置为准，每次启动对一下（换了签名或位置后系统里的登记可能失效）
        if !test, store.settings.launchAtLogin != LoginItem.enabled { LoginItem.set(store.settings.launchAtLogin) }

        // 一次性的搬家标记：放了这个文件，下次启动时自动搬一次 SideNotes，然后删掉标记
        let once = ReachPaths.home.appendingPathComponent("import-sidenotes.once")
        if !test, FileManager.default.fileExists(atPath: once.path) {
            try? FileManager.default.removeItem(at: once)
            importSideNotes()
        }
        if ProcessInfo.processInfo.environment["REACH_SHOW"] == "1" { panelController.show(.menu) }
        // 新版本第一次打开：告诉一声截图快捷键
        if !test, !UserDefaults.standard.bool(forKey: "shotIntroShown") {
            UserDefaults.standard.set(true, forKey: "shotIntroShown")
            let label = model.settings.shotKey.label
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.toast.show(self.shotHotkeyOK ? "按 \(label) 截图，截图里的密钥会自动打码（设置里可以换快捷键）" : "新功能：截图。\(label) 被别的 App 占用了，可以在设置里换一个快捷键")
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) { bridge?.stop() }

    // MARK: 截图

    @objc func takeShot() {
        // 从菜单点的：等菜单收起再冻住屏幕
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.shot.start() }
    }

    /// 按设置注册快捷键：1 打开侧栏，2 备用的 ⌃⌥V，3 截图。注册不上（被别的 App 占了）时对应的 OK 为 false，设置里会提示换一个
    func applyHotkeys() {
        for id: UInt32 in [1, 2, 3] { HotKey.unregister(id: id) }
        let s = model.settings
        hotkeyOK = HotKey.register(id: 1, key: UInt32(s.panelKey.code), mods: UInt32(s.panelKey.mods)) { [weak self] in self?.panelController.toggle() }
        let backup = KeyCombo.backupPanel
        hotkey2OK = s.panelKey != backup && s.shotKey != backup
            && HotKey.register(id: 2, key: UInt32(backup.code), mods: UInt32(backup.mods)) { [weak self] in self?.panelController.toggle() }
        shotHotkeyOK = s.shotHotkey && s.shotKey != s.panelKey
            && HotKey.register(id: 3, key: UInt32(s.shotKey.code), mods: UInt32(s.shotKey.mods)) { [weak self] in self?.shot.start() }
        appliedKeys = (s.panelKey, s.shotKey, s.shotHotkey)
    }
    private(set) var appliedKeys: (KeyCombo, KeyCombo, Bool)?

    /// 设置里录快捷键时先放开，免得按下去直接触发
    func suspendHotkeys(_ on: Bool) {
        if on { for id: UInt32 in [1, 2, 3] { HotKey.unregister(id: id) } } else { applyHotkeys() }
    }

    @objc func toggleShotRedact() { model.settings.shotRedact.toggle() }

    // MARK: 菜单

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, checked: Bool = false, key: String = "") {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        i.state = checked ? .on : .off
        menu.addItem(i)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = model.settings
        add(menu, hotkeyOK ? "打开手边（\(s.panelKey.label)）" : "打开手边", #selector(openPanel))
        add(menu, shotHotkeyOK ? "截图（\(s.shotKey.label)）" : "截图", #selector(takeShot))
        add(menu, "截图时自动遮住密钥", #selector(toggleShotRedact), checked: s.shotRedact)
        menu.addItem(.separator())
        add(menu, "暂停记录", #selector(togglePause), checked: s.paused)
        if s.links.enabled { add(menu, "暂停链接分流", #selector(toggleLinkPause), checked: s.links.paused) }
        else { add(menu, "链接分流（点链接自动去对的浏览器）…", #selector(openSettings)) }
        add(menu, "普通 ⌘V 也按目标窗口调整格式", #selector(toggleAmbient), checked: s.ambientFormat)
        menu.addItem(.separator())
        add(menu, Connect.claudeConnected ? "断开 Claude Code" : "连接 Claude Code…", #selector(toggleClaude), checked: Connect.claudeConnected)
        add(menu, Connect.codexConnected ? "断开 Codex" : "连接 Codex…", #selector(toggleCodex), checked: Connect.codexConnected)
        add(menu, Connect.cliInstalled ? "命令行 reach 已安装" : "安装命令行 reach…", #selector(installCLI), checked: Connect.cliInstalled)
        add(menu, "复制给 Agent 的使用说明", #selector(copyGuide))
        menu.addItem(.separator())
        if SideNotesImporter.available != nil { add(menu, "从 SideNotes 搬家…", #selector(importSideNotesAction)) }
        add(menu, "清空复制历史…", #selector(clearHistory))
        add(menu, "开机自动打开", #selector(toggleLogin), checked: LoginItem.enabled)
        add(menu, "设置…", #selector(openSettings), key: ",")
        if !Keys.trusted { add(menu, "允许自动粘贴（打开辅助功能设置）…", #selector(askTrust)) }
        menu.addItem(.separator())
        add(menu, "退出手边", #selector(quit), key: "q")
    }

    private func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    @objc func openPanel() { panelController.show(.menu) }
    @objc func togglePause() { model.settings.paused.toggle(); toast.show(model.settings.paused ? "已暂停记录" : "恢复记录") }
    @objc func toggleLinkPause() {
        model.settings.links.paused.toggle()
        toast.show(model.settings.links.paused ? "链接分流已暂停：链接都开在默认去处" : "链接分流恢复")
    }
    @objc func toggleAmbient() { model.settings.ambientFormat.toggle() }
    @objc func askTrust() { Keys.promptTrust() }
    @objc func toggleLogin() {
        let on = !LoginItem.enabled
        model.settings.launchAtLogin = on
        if let e = LoginItem.set(on) { toast.show("没设置成功：\(e)。可以在 系统设置 › 通用 › 登录项 里手动加上「手边」。") }
        else { toast.show(on ? "开机会自动打开手边" : "开机不再自动打开") }
    }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleClaude() {
        if Connect.claudeConnected {
            if confirm("断开 Claude Code？", "会从 ~/.claude/settings.json 里去掉手边的钩子，并取消注册工具。", ok: "断开") { toast.show(Connect.disconnectClaude()) }
        } else if confirm("连接 Claude Code", "会做两件事：\n1. 在 ~/.claude/settings.json 里加上钩子，让 Claude Code 在等你确认、完成时告诉手边（改之前先备份）。\n2. 把手边注册成它的工具，它需要账号、密钥时可以来查，密钥要你批准才给。", ok: "连接") {
            toast.show(Connect.connectClaude())
        }
    }

    @objc func toggleCodex() {
        if Connect.codexConnected {
            if confirm("断开 Codex？", "会从 ~/.codex/config.toml 里去掉手边。", ok: "断开") { toast.show(Connect.disconnectCodex()) }
        } else if confirm("连接 Codex", "会在 ~/.codex/config.toml 里把手边注册成它的工具（改之前先备份）。Codex 需要账号、密钥时可以来查，密钥要你批准才给。", ok: "连接") {
            toast.show(Connect.connectCodex())
        }
    }

    @objc func installCLI() { toast.show(Connect.installCLI()) }

    @objc func copyGuide() {
        Pasteboard.write(Payload(plain: Connect.agentGuide)); monitor.syncCount()
        toast.show("已复制。贴进项目的 AGENTS.md 或 CLAUDE.md，任何 Agent 都能用命令行查手边。")
    }

    @objc func importSideNotesAction() { importSideNotes() }

    @discardableResult
    func importSideNotes() -> [String: Any] {
        guard let url = SideNotesImporter.available else { toast.show("没找到 SideNotes 的数据"); return ["error": "没找到 SideNotes 的数据"] }
        let r = SideNotesImporter.importInto(model.store, from: url)
        model.sideNotesHint = nil
        model.rebuild()
        defer { toast.show(r.notes == 0 ? "没有新的可搬（已经搬过了）。" : "搬过来 \(r.notes) 条、\(r.folders) 个文件夹，其中 \(r.withSecrets) 条里的密钥已打码。SideNotes 里的原件没有动。") }
        return ["ok": true, "notes": r.notes, "folders": r.folders, "with_secrets": r.withSecrets, "skipped": r.skipped]
    }

    @objc func clearHistory() {
        guard confirm("清空复制历史？", "留存的内容不受影响。清空后不能恢复。", ok: "清空") else { return }
        for it in model.store.clips { model.store.delete(it.id) }
        model.rebuild()
    }

    @objc func openSettings() {
        panelController.hide()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "手边设置"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// 开机自动打开（系统设置 › 通用 › 登录项 里能看到、能关）
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on { if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() } }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch { return error.localizedDescription }
    }
}
