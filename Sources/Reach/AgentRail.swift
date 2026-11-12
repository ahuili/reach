import AppKit
import ReachCore

/// Agent 进展栏：定时读各个 Agent 的会话记录；装了钩子的 Claude Code 还会主动报"在等你"。
final class AgentRail {
    let model: AppModel
    var store: Store { model.store }
    private var timer: Timer?
    private var scanning = false
    private var known: [String: AgentState] = [:]
    private var firstScan = true
    /// 钩子报上来的状态，比读文件准
    private var hooks: [String: (state: AgentState, detail: String, at: Date, host: String?)] = [:]
    var onNeedsYou: () -> Void = {}

    init(model: AppModel) { self.model = model }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if !model.agents.isEmpty { model.agents = []; model.rebuild() }
    }

    var running: Bool { timer != nil }

    private func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = AgentScanner.scan()
            DispatchQueue.main.async { self?.apply(found); self?.scanning = false }
        }
    }

    private func apply(_ found: [AgentSession]) {
        let now = Date()
        var list: [AgentSession] = []
        for var s in found {
            if let h = hooks[s.id] {
                if let host = h.host { s.hostBundle = s.hostBundle ?? host }
                // 钩子的消息比文件里最后的变化新，才用钩子的
                if h.at >= s.updatedAt.addingTimeInterval(-2) {
                    s.state = h.state
                    if !h.detail.isEmpty { s.detail = h.detail }
                    s.updatedAt = max(s.updatedAt, h.at)
                } else { hooks[s.id] = nil }
            }
            let prev = known[s.id]
            if !firstScan, s.state == .done, prev != nil, prev != .done { captureOutputs(s) }
            if !firstScan, s.state == .waiting, prev != .waiting { onNeedsYou() }
            known[s.id] = s.state
            switch s.state {
            case .running, .waiting, .maybeWaiting: list.append(s)
            case .done: if now.timeIntervalSince(s.updatedAt) < 30 * 60 { list.append(s) }
            case .idle: break
            }
        }
        firstScan = false
        // 等你的排最前，然后是在跑的，最后是刚完成的
        func pri(_ s: AgentSession) -> Int {
            switch s.state { case .waiting: return 0; case .maybeWaiting: return 1; case .running: return 2; default: return 3 }
        }
        list.sort { pri($0) != pri($1) ? pri($0) < pri($1) : $0.updatedAt > $1.updatedAt }
        if list != model.agents { model.agents = list; model.rebuild() }
    }

    /// Agent 这一轮给出的命令、链接，自动变成"最近复制"里的卡片
    private func captureOutputs(_ s: AgentSession) {
        let outs = AgentScanner.outputs(from: s.lastMessage)
        guard !outs.isEmpty else { return }
        let gid = "agent-" + s.id
        store.setGroupName(gid, "\(s.agent.name) · \(s.project.isEmpty ? "产出" : s.project)")
        let now = Date()
        for (i, o) in outs.enumerated() {
            let hash = store.vault.fingerprint(Data(o.text.utf8))
            if store.find(hash: hash, kind: .clip) != nil || store.find(hash: hash, kind: .kept) != nil { continue }
            var it = Item(kind: .clip, ctype: o.type, text: o.text, sourceApp: s.agent.name, origin: .agent, agentSession: s.id,
                          createdAt: now.addingTimeInterval(-Double(i) * 0.01), groupId: gid, hash: hash)
            if SecretDetector.isWholeSecret(o.text) {
                it.sensitive = true; it.ctype = .secret
                it.expiresAt = now.addingTimeInterval(Double(store.settings.secretClipMinutes) * 60)
            } else {
                it.expiresAt = now.addingTimeInterval(Double(store.settings.retentionDays) * 86400)
            }
            store.save(it)
        }
        model.rebuild()
    }

    // MARK: 钩子事件（Claude Code）

    /// 返回 true 表示这次要等用户在侧栏里点批准
    func handleHook(agent: String, payload: [String: Any], host: String?) {
        guard let sid = payload["session_id"] as? String, let event = payload["hook_event_name"] as? String else { return }
        let now = Date()
        switch event {
        case "Notification":
            let msg = payload["message"] as? String ?? ""
            let type = payload["notification_type"] as? String ?? ""
            if type == "permission_prompt" || type == "idle_prompt" || msg.contains("permission") || msg.contains("waiting") {
                hooks[sid] = (.waiting, msg.isEmpty ? "在等你" : msg, now, host)
            }
        case "PermissionRequest":
            let tool = payload["tool_name"] as? String ?? "工具"
            hooks[sid] = (.waiting, "要你确认：" + AgentScanner.brief(tool: tool, input: payload["tool_input"] as? [String: Any]), now, host)
        case "UserPromptSubmit", "SessionStart":
            hooks[sid] = (.running, "", now, host)
        case "Stop":
            hooks[sid] = nil
            if let h = host { hooks[sid] = (.done, "", now.addingTimeInterval(-3), h) }
        case "SessionEnd":
            hooks[sid] = nil
        default: break
        }
        scan()
    }

    // MARK: 递给 Agent

    func jump(to s: AgentSession) {
        if let b = s.hostBundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
            model.hidePanel()
            app.activate()
        } else {
            model.toast("这个会话在终端里，手边不知道是哪个窗口。装上钩子（菜单 › 连接 Claude Code）后就能直接跳过去。")
        }
    }

    func send(text: String, to s: AgentSession) {
        Pasteboard.write(Payload(plain: text))
        model.paster.monitor?.syncCount()
        if let b = s.hostBundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first {
            model.hidePanel()
            app.activate()
            if Keys.trusted {
                // 贴进输入框，不替你按回车：发不发由你看一眼再定
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Keys.pasteKey() }
                model.toast("已贴进 \(s.agent.name) 的输入框，看一眼再回车")
            } else {
                model.toast("已复制并切到 \(s.agent.name)，按 ⌘V 贴进去")
            }
        } else {
            model.toast("已复制。切到跑着 \(s.agent.name) 的那个终端，按 ⌘V 贴进去")
        }
    }

    func send(items ids: [String], to s: AgentSession) {
        let saved = model.basket
        model.basket = ids
        let text = ids.count == 1 ? (store.items[ids[0]].map { $0.ctype == .image ? ($0.ocr ?? "") : $0.text } ?? "") : model.basketText()
        model.basket = saved.filter { !ids.contains($0) }
        guard !text.isEmpty else { model.toast("这条没有可发的文字"); return }
        // 密钥不随手发给 Agent：要给密钥，走 Agent 申请、你批准那条路
        if ids.compactMap({ store.items[$0] }).contains(where: { $0.sensitive || $0.ctype == .secret }) {
            model.toast("这里面有密钥，没有发。Agent 需要密钥时会来申请，由你批准。")
            return
        }
        for id in ids { store.recordUse(id, app: s.hostBundle) }
        send(text: text, to: s)
    }
}
