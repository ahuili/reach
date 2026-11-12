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
    let toast = Toast()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()
    private var purgeTimer: Timer?
    private(set) var hotkeyOK = false
    private(set) var hotkey2OK = false

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
            a.informativeText = "读不到钥匙串里的数据库密钥（\(error)）。如果系统刚才问过是否允许手边访问钥匙串，请选「始终允许」后重新打开。"
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
        model.paster = paster
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
        bridge.testMode = test
        bridge.monitor = monitor
        store.purgeExpired()
        if !test { monitor.start() }
        panelController.refreshHandles()
        if store.settings.agentRail { rail.start() }
        if !bridge.start() { toast.show("手边的本机通信没起来，Agent 暂时连不上它。") }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            if (self?.model.store.purgeExpired() ?? 0) > 0 { self?.model.rebuild() }
        }

        let ok = test || HotKey.register(id: 1, key: UInt32(kVK_ANSI_V), mods: UInt32(cmdKey | shiftKey)) { [weak self] in self?.panelController.toggle() }
        hotkeyOK = ok && !test
        if !test { hotkey2OK = HotKey.register(id: 2, key: UInt32(kVK_ANSI_V), mods: UInt32(controlKey | optionKey)) { [weak self] in self?.panelController.toggle() } }
        if !ok { toast.show("⇧⌘V 被别的 App 占着（多半是 Paste）。先用 ⌃⌥V 叫出手边，或者退出 Paste。") }

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
    }

    func applicationWillTerminate(_ note: Notification) { bridge?.stop() }

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
        add(menu, "打开手边（⇧⌘V）", #selector(openPanel))
        menu.addItem(.separator())
        add(menu, "暂停记录", #selector(togglePause), checked: s.paused)
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
