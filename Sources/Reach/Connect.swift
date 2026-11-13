import AppKit
import SwiftUI
import ReachCore

/// 把手边接到各个 Agent 上。都是用户在菜单里点了才做，改配置文件前先留备份。
enum Connect {
    static var cli: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/reachctl").path }
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    static var cliLink: URL { home.appendingPathComponent(".local/bin/reach") }
    static let hookEvents = ["SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest", "Stop", "SessionEnd"]

    static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: url.path + ".reach-backup-" + f.string(from: Date())))
    }

    // MARK: Claude Code

    static var claudeConnected: Bool {
        (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains("reachctl") ?? false
    }

    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for (event, v) in hooks {
            guard let groups = v as? [[String: Any]] else { continue }
            let kept = groups.filter { g in
                !((g["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains("reachctl") })
            }
            if kept.isEmpty { out[event] = nil } else { out[event] = kept }
        }
        return out
    }

    private static func claudeBinary() -> String? {
        let c = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                 home.appendingPathComponent(".claude/local/claude").path]
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ bin: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    static func connectClaude() -> String {
        var root: [String: Any] = [:]
        if let d = try? Data(contentsOf: claudeSettings) {
            guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return "settings.json 读不懂，没有改动。" }
            root = o
        }
        backup(claudeSettings)
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        for e in hookEvents {
            var groups = hooks[e] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": "\"\(cli)\" hook claude", "timeout": e == "PermissionRequest" ? 60 : 5]]])
            hooks[e] = groups
        }
        root["hooks"] = hooks
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "写不出配置。" }
        do {
            try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: claudeSettings, options: .atomic)
        } catch { return "写 settings.json 失败：\(error.localizedDescription)" }
        var msg = "已装上钩子：Claude Code 等你确认、完成时会报给手边。原配置已备份在同目录。"
        if let bin = claudeBinary() {
            run(bin, ["mcp", "remove", "--scope", "user", "reach"])
            msg += run(bin, ["mcp", "add", "--scope", "user", "reach", "--", cli, "mcp"]) == 0 ? "也已把手边注册成它的工具（MCP）。" : "但注册工具（MCP）没成功，可以手动运行：claude mcp add --scope user reach -- \"\(cli)\" mcp"
        } else {
            msg += "没找到 claude 命令，注册工具请手动运行：claude mcp add --scope user reach -- \"\(cli)\" mcp"
        }
        return msg + " 新开的会话生效。"
    }

    static func disconnectClaude() -> String {
        guard let d = try? Data(contentsOf: claudeSettings), var root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return "没有可断开的。" }
        backup(claudeSettings)
        let hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { try? out.write(to: claudeSettings, options: .atomic) }
        if let bin = claudeBinary() { run(bin, ["mcp", "remove", "--scope", "user", "reach"]) }
        return "已从 Claude Code 断开。"
    }

    // MARK: Codex

    static var codexConnected: Bool {
        (try? String(contentsOf: codexConfig, encoding: .utf8))?.contains("[mcp_servers.reach]") ?? false
    }

    static func connectCodex() -> String {
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if text.contains("[mcp_servers.reach]") { text = removeCodexBlock(text) }
        backup(codexConfig)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "\n[mcp_servers.reach]\ncommand = \"\(cli)\"\nargs = [\"mcp\"]\n"
        do {
            try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: codexConfig, atomically: true, encoding: .utf8)
            return "已把手边注册成 Codex 的工具（MCP）。原配置已备份在同目录。重开 Codex 后生效。Codex 的进展不用配置就能在侧栏看到。"
        } catch { return "写 config.toml 失败：\(error.localizedDescription)" }
    }

    private static func removeCodexBlock(_ text: String) -> String {
        var out: [String] = []
        var skipping = false
        for l in text.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t == "[mcp_servers.reach]" { skipping = true; continue }
            if skipping, t.hasPrefix("[") { skipping = false }
            if !skipping { out.append(l) }
        }
        return out.joined(separator: "\n")
    }

    static func disconnectCodex() -> String {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8), text.contains("[mcp_servers.reach]") else { return "没有可断开的。" }
        backup(codexConfig)
        try? removeCodexBlock(text).write(to: codexConfig, atomically: true, encoding: .utf8)
        return "已从 Codex 断开。"
    }

    // MARK: 命令行

    static var cliInstalled: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink.path)) == cli }

    static func installCLI() -> String {
        do {
            try FileManager.default.createDirectory(at: cliLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: cliLink)
            try FileManager.default.createSymbolicLink(atPath: cliLink.path, withDestinationPath: cli)
        } catch { return "安装失败：\(error.localizedDescription)" }
        let inPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").contains(".local/bin")
        return "已安装命令 reach（~/.local/bin/reach）。" + (inPath ? "" : "如果终端里找不到它，把 ~/.local/bin 加进 PATH。")
    }

    /// 给任何 Agent 的一段说明，贴进 AGENTS.md / CLAUDE.md 就能用（不依赖 MCP）
    static var agentGuide: String {
        """
        ## 手边 Reach（本机的账号、密钥、连接信息）

        需要服务器地址、后台入口、账号、API Key 时，先查手边，不要问我要，也不要让我把密钥贴进对话：

        - `reach search <关键词>`：搜我留存的和最近复制的内容（密钥是打码的）
        - `reach read <id>`：读一条的全文（密钥位置是占位）
        - `reach recent 5`：我最近复制的几条
        - `reach env match NAME1 NAME2 --project .`：看这些配置名在手边里有没有对应的 Key
        - `reach env write NAME1 NAME2 --project .`：我批准后，手边把值直接写进项目的 .env（值不经过你）
        - `reach run --env DB_PASS="staging 数据库" -- <命令>`：我批准后，带着这个密钥运行一条命令
        - `echo "内容" | reach save --title "标题" --folder "文件夹"`：你新建了账号、Token 时，存回手边

        凡是涉及密钥的，我会在屏幕边上看到一张卡片并点允许；被拒绝就停下来问我。
        """
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var s: ReachCore.Settings
    @State private var status = ""
    @State private var testing = false

    init(model: AppModel) { self.model = model; _s = State(initialValue: model.settings) }

    private let presets: [(String, String, String)] = [
        ("Ollama（本机，不出电脑）", "http://127.0.0.1:11434/v1", "qwen2.5:7b"),
        ("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
        ("阿里云百炼", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
        ("智谱（glm-4-flash 免费）", "https://open.bigmodel.cn/api/paas/v4", "glm-4-flash"),
    ]

    var body: some View {
        Form {
            Section("启动") {
                Toggle("开机自动打开", isOn: $s.launchAtLogin)
            }
            Section("记录") {
                Toggle("暂停记录复制的内容", isOn: $s.paused)
                Stepper("复制历史保留 \(s.retentionDays) 天", value: $s.retentionDays, in: 1...180)
                Stepper("复制到的密钥 \(s.secretClipMinutes) 分钟后清除", value: $s.secretClipMinutes, in: 5...720, step: 5)
            }
            Section("侧栏") {
                Toggle("屏幕边上露一个小把手", isOn: $s.edgeHandle)
                Text("鼠标滑到把手上或点一下就打开侧栏，上下拖可以挪位置。旁边紧挨着另一块屏、边缘碰不到时用它。").font(.caption).foregroundStyle(.secondary)
                Toggle("鼠标甩到屏幕边缘时滑出", isOn: $s.hotEdge)
                Picker("在哪一侧", selection: $s.edgeLeft) { Text("右边").tag(false); Text("左边").tag(true) }.pickerStyle(.segmented)
            }
            Section("快捷键") {
                LabeledContent("打开侧栏") { KeyRecorder(combo: $s.panelKey, fallback: KeyCombo.defaultPanel) }
                if let app = NSApp.delegate as? AppDelegate, app.appliedKeys?.0 == s.panelKey, !app.hotkeyOK {
                    Text("这组键被别的 App 占用了（多半是 Paste），换一个试试。").font(.caption).foregroundStyle(Palette.warn)
                }
                Toggle("用快捷键截图", isOn: $s.shotHotkey)
                if s.shotHotkey {
                    LabeledContent("截图") { KeyRecorder(combo: $s.shotKey, fallback: KeyCombo.defaultShot) }
                    if s.shotKey == s.panelKey {
                        Text("和打开侧栏用的是同一组键，换一个。").font(.caption).foregroundStyle(Palette.warn)
                    } else if let app = NSApp.delegate as? AppDelegate, app.appliedKeys?.1 == s.shotKey, !app.shotHotkeyOK {
                        Text("这组键被别的 App 占用了，换一个试试。").font(.caption).foregroundStyle(Palette.warn)
                    }
                }
                Text("点一下按钮，再按下想用的组合键（要带 ⌘ ⌃ ⌥ 之一，或者 F1–F12）；Esc 取消。⌃⌥V 一直可以打开侧栏，作备用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("截图") {
                Toggle("截图里认出的密钥自动打码", isOn: $s.shotRedact)
                Text("截完先认字：Key、密码、Token、带密码的连接串所在的位置直接打上马赛克，工具栏上点一下可以取消。截图需要「屏幕录制」权限。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("粘贴") {
                Toggle("普通的 ⌘V 也按目标窗口调整格式", isOn: $s.ambientFormat)
                Text("从 AI 那里复制的内容带着 ** ## 这些记号。切到微信、企业微信等聊天窗口时自动换成干净文字，切到邮件、Word 时带上格式；切走后恢复原样。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent") {
                Toggle("在侧栏顶上显示 Agent 进展（试验中）", isOn: $s.agentRail)
                Text("显示 Claude Code、Codex 在跑的会话。还在重新设计，默认关。截图贴进终端变成文件路径、Agent 来查账号密钥这些不受影响。").font(.caption).foregroundStyle(.secondary)
                Toggle("在侧栏里批准 Claude Code 的操作", isOn: $s.sidebarApprove)
                Text("开着时，Claude Code 每次要确认都会先在侧栏等最多 50 秒，终端里的确认框会晚出现。需要先在菜单里连接 Claude Code。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI（给一组复制起名、留存时自动归文件夹、翻译和精简）") {
                Toggle("启用", isOn: $s.ai.enabled)
                Picker("预设", selection: Binding(get: { -1 }, set: { i in if i >= 0 { s.ai.baseURL = presets[i].1; s.ai.model = presets[i].2 } })) {
                    Text("选一个填好地址…").tag(-1)
                    ForEach(0..<presets.count, id: \.self) { Text(presets[$0].0).tag($0) }
                }
                TextField("接口地址（OpenAI 兼容，通常以 /v1 结尾）", text: $s.ai.baseURL)
                TextField("模型名", text: $s.ai.model)
                SecureField("API Key（本机模型不用填）", text: $s.ai.apiKey)
                HStack {
                    Button(testing ? "测试中…" : "测试一下") { test() }.disabled(testing || s.ai.baseURL.isEmpty || s.ai.model.isEmpty)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("发给模型的内容会先在本机把密码和 Key 抹掉。不启用也不影响其他功能。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onChange(of: s) { new in
            model.settings = new
            model.rebuild()
            if let app = NSApp.delegate as? AppDelegate {
                app.panelController.refreshHandles()
                if new.agentRail, !model.rail.running { model.rail.start() } else if !new.agentRail, model.rail.running { model.rail.stop() }
                if new.launchAtLogin != LoginItem.enabled { LoginItem.set(new.launchAtLogin) }
                if let a = app.appliedKeys, a.0 != new.panelKey || a.1 != new.shotKey || a.2 != new.shotHotkey { app.applyHotkeys() }
            }
        }
    }

    private func test() {
        testing = true; status = ""
        var cfg = s.ai; cfg.enabled = true
        Task { @MainActor in
            do { status = "通了：" + (try await AIClient(cfg).complete(system: "只回答两个字：可以", user: "测试", maxTokens: 10, timeout: 20)) }
            catch { status = "没通：\(error)" }
            testing = false
        }
    }
}

/// 录快捷键：点一下，按下新的组合键。要带 ⌘ ⌃ ⌥ 之一（或者是 F 键），Esc 取消
struct KeyRecorder: View {
    @Binding var combo: KeyCombo
    let fallback: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    private static let names: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        49: "空格", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    ]
    private static let fKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    var body: some View {
        HStack(spacing: 8) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "按下新的快捷键…" : combo.label)
                    .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 120)
            }
            if combo != fallback && !recording {
                Button("恢复默认") { combo = fallback }.buttonStyle(.link)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        (NSApp.delegate as? AppDelegate)?.suspendHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods = 0, label = ""
            if f.contains(.control) { mods |= 4096; label += "⌃" }
            if f.contains(.option) { mods |= 2048; label += "⌥" }
            if f.contains(.shift) { mods |= 512; label += "⇧" }
            if f.contains(.command) { mods |= 256; label += "⌘" }
            guard mods & (4096 | 2048 | 256) != 0 || Self.fKeys.contains(e.keyCode) else { NSSound.beep(); return nil }
            let key = Self.names[e.keyCode] ?? (e.characters(byApplyingModifiers: [])?.uppercased() ?? "")
            guard !key.isEmpty, !key.unicodeScalars.contains(where: { $0.value < 32 }) else { NSSound.beep(); return nil }
            combo = KeyCombo(code: Int(e.keyCode), mods: mods, label: label + key)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording { recording = false; (NSApp.delegate as? AppDelegate)?.suspendHotkeys(false) }
    }
}
