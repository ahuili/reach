import AppKit
import ReachCore

/// 命令行和 MCP 进来的请求都在这里处理。凡是会交出密钥、写文件、存东西的，都先在侧栏里等你点头。
final class Bridge {
    let model: AppModel
    var store: Store { model.store }
    var showPanel: () -> Void = {}
    private var server: IPCServer?
    var testMode = false
    weak var monitor: ClipboardMonitor?

    init(model: AppModel) { self.model = model }

    func start() -> Bool {
        server = IPCServer { [weak self] req, reply in
            guard let self else { reply(["error": "gone"]); return }
            self.handle(req, reply)
        }
        return server?.start() ?? false
    }

    func stop() { server?.stop() }

    private func summary(_ it: Item) -> [String: Any] {
        let body = it.ctype == .image ? (it.ocr ?? "（图片）") : it.text
        return ["id": it.id, "title": SecretDetector.mask(it.displayTitle, loose: it.kind == .kept, ignoring: it.notSecret),
                "type": it.ctype.rawValue, "kind": it.kind.rawValue, "folder": model.folderName(it.folderId),
                "preview": Text.truncate(SecretDetector.mask(body, loose: it.kind == .kept, ignoring: it.notSecret), 240),
                "has_secret": it.sensitive || it.ctype == .secret || it.ctype == .credential,
                "source": it.sourceApp ?? "", "time": ISO8601DateFormatter().string(from: it.createdAt)]
    }

    private func search(_ q: String, limit: Int) -> [Item] {
        let tokens = q.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let hits = store.items.values.filter { it in
            let hay = (it.searchable + "\n" + model.folderName(it.folderId)).lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        return hits.sorted { a, b in
            if a.kind != b.kind { return a.kind == .kept }
            return (a.lastUsedAt ?? a.createdAt) > (b.lastUsedAt ?? b.createdAt)
        }.prefix(limit).map { $0 }
    }

    private func handle(_ req: [String: Any], _ reply: @escaping ([String: Any]) -> Void) {
        let cmd = req["cmd"] as? String ?? ""
        let agent = req["agent"] as? String ?? "命令行"
        switch cmd {
        case "ping":
            reply(["ok": true, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"])
        case "status":
            // 只有数量和开关，不含任何内容
            let app = NSApp.delegate as? AppDelegate
            reply(["ok": true, "clips": store.clips.count, "kept": store.kept.count, "folders": store.folders.count,
                   "sensitive": store.items.values.filter { $0.sensitive }.count,
                   "hotkey": app?.hotkeyOK ?? false, "hotkey2": app?.hotkey2OK ?? false, "autopaste": Keys.trusted,
                   "paused": store.settings.paused, "agents": model.agents.count,
                   "claude": Connect.claudeConnected, "codex": Connect.codexConnected, "cli": Connect.cliInstalled, "login": LoginItem.enabled])
        case "import.sidenotes":
            guard let app = NSApp.delegate as? AppDelegate else { reply(["error": "gone"]); return }
            reply(app.importSideNotes())
        case "show":
            showPanel(); reply(["ok": true])
        case "search":
            let items = search(req["q"] as? String ?? "", limit: req["limit"] as? Int ?? 10)
            reply(["ok": true, "items": items.map(summary)])
        case "recent":
            let n = min(req["n"] as? Int ?? 5, 30)
            reply(["ok": true, "items": store.clips.filter { !$0.sensitive }.prefix(n).map { it -> [String: Any] in
                var s = summary(it)
                s["text"] = it.ctype == .image ? (it.ocr ?? "") : SecretDetector.mask(it.text)
                return s
            }])
        case "read":
            guard let id = req["id"] as? String, let it = store.items[id] else { reply(["error": "没有这条"]); return }
            var n = 0
            let body = it.ctype == .image ? (it.ocr ?? "") : it.text
            let text = SecretDetector.replace(body, loose: it.kind == .kept, ignoring: it.notSecret) { s in n += 1; return "‹\(s.label) \(n)，已隐藏›" }
            var out = summary(it)
            out["text"] = text
            if n > 0 { out["note"] = "这条里有 \(n) 个密钥没有给出。需要用时调用 request_secret 或 write_env，由用户批准。" }
            reply(["ok": true, "item": out])
        case "env.match":
            let names = req["names"] as? [String] ?? []
            let project = req["project"] as? String ?? ""
            let ms = EnvMatcher.match(names: names, items: Array(store.items.values), folders: store.folders, bindings: store.bindings[project] ?? [:])
            reply(["ok": true, "matches": ms.map { m -> [String: Any] in
                ["name": m.name, "status": m.best != nil ? "matched" : (m.candidates.isEmpty ? "missing" : "ambiguous"),
                 "candidates": m.candidates.map { ["title": $0.title, "folder": $0.folder, "masked": $0.masked] }]
            }])
        case "env.write": envWrite(req, agent: agent, reply)
        case "secret.get": secretGet(req, agent: agent, reply)
        case "save": saveNote(req, agent: agent, reply)
        case "hook": hook(req, reply)
        default:
            if testMode, cmd.hasPrefix("debug.") { debug(cmd, req, reply) } else { reply(["error": "不认识的命令：\(cmd)"]) }
        }
    }

    /// 只在测试模式下可用：数据在临时目录里，够不着真实的库
    private func debug(_ cmd: String, _ req: [String: Any], _ reply: @escaping ([String: Any]) -> Void) {
        let app = NSApp.delegate as? AppDelegate
        switch cmd {
        case "debug.ingest":
            let text = req["text"] as? String ?? ""
            var it = Item(kind: .clip, text: text, sourceApp: req["app"] as? String, sourceBundle: req["bundle"] as? String,
                          hash: store.vault.fingerprint(Data(text.utf8)))
            it.ctype = Classifier.classify(text)
            if let p = req["image"] as? String, let png = FileManager.default.contents(atPath: p), let file = store.saveImage(png) {
                it.ctype = .image; it.imageFile = file; it.hash = store.vault.fingerprint(png)
            }
            monitor?.ingest(&it)
            reply(["ok": true, "id": monitor?.lastCapturedId ?? "", "type": it.ctype.rawValue])
        case "debug.kept":
            let text = req["text"] as? String ?? ""
            var it = Item(kind: .kept, text: text, origin: .manual, hash: store.vault.fingerprint(Data(text.utf8)))
            it.title = req["title"] as? String ?? ""
            if let f = req["folder"] as? String { it.folderId = store.folder(named: f).id; model.expandedFolders.insert(it.folderId!) }
            let secrets = SecretDetector.find(in: text, loose: true)
            it.sensitive = !secrets.isEmpty
            it.ctype = secrets.isEmpty ? Classifier.classify(text) : (SecretDetector.isWholeSecret(text) ? .secret : .credential)
            if let n = req["uses"] as? Int { it.useCount = n; it.lastUsedAt = Date() }
            store.save(it); model.rebuild()
            reply(["ok": true, "id": it.id])
        case "debug.payload":
            guard let id = req["id"] as? String, let it = store.items[id] else { reply(["error": "no item"]); return }
            let target = TargetKind(rawValue: req["target"] as? String ?? "other") ?? .other
            let mode: PasteMode = { switch req["mode"] as? String { case "plain": return .plain; case "raw": return .raw; case "clean": return .cleanText; default: return .smart } }()
            let p = model.paster.payload(it, mode: mode, target: target)
            reply(["ok": true, "plain": p?.plain ?? "", "html": p?.html ?? "", "secret": p?.containsSecret ?? false])
        case "debug.ui":
            if let q = req["query"] as? String { model.query = q }
            if let t = req["tab"] as? String, let tab = Tab(rawValue: t) { model.tab = tab }
            if let f = req["folder"] as? String { model.folderFilter = f == "@common" ? f : model.store.folders.first { $0.name == f }?.id }
            if let n = req["pick"] as? Int { model.basket = Array(model.selectable.prefix(n)) }
            if req["new"] as? Bool == true { model.newNote() }
            if let b = req["folders"] as? Bool { model.managingFolders = b }
            if let n = req["selectIndex"] as? Int, model.selectable.indices.contains(n) { model.selection = model.selectable[n] }
            if req["activateSelected"] as? Bool == true, let it = model.selectedItem { model.activate(it) }
            if let b = req["sidebarApprove"] as? Bool { model.settings.sidebarApprove = b }
            if let id = req["select"] as? String { model.selection = id }
            if let t = req["target"] as? String { model.targetBundle = t; model.targetName = req["targetName"] as? String ?? t; model.rebuild() }
            if req["options"] as? Bool == true { model.openOptions() } else if req["options"] as? Bool == false { model.options = nil }
            if req["edit"] as? Bool == true, let it = model.selectedItem { model.edit(it) } else if req["edit"] as? Bool == false { model.editor = nil }
            if let ids = req["basket"] as? [String] { model.basket = ids }
            if let id = req["activate"] as? String, let it = store.items[id] { model.paster.paste(it, mode: .smart) }
            if let n = req["approve"] as? Int, model.approvals.indices.contains(n) { model.resolve(model.approvals[n], allow: req["allow"] as? Bool ?? true) }
            app?.panelController.show(.approval)
            reply(["ok": true, "rows": model.rows.map(\.id).count, "approvals": model.approvals.map(\.title), "confirm": model.confirmSecret != nil,
                   "options": (model.options ?? []).map { $0.label + " " + $0.detail }, "agents": model.agents.map { "\($0.agent.name)|\($0.project)|\($0.state.rawValue)|\($0.detail)" }])
        case "debug.snapshot":
            let ok = app?.panelController.snapshot(to: req["path"] as? String ?? "") ?? false
            reply(["ok": ok])
        default: reply(["error": "unknown debug"])
        }
    }

    private func present(_ a: Approval) {
        model.addApproval(a)
        showPanel()
        NSSound(named: "Tink")?.play()
    }

    private func envWrite(_ req: [String: Any], agent: String, _ reply: @escaping ([String: Any]) -> Void) {
        let names = req["names"] as? [String] ?? []
        guard let project = req["project"] as? String, !project.isEmpty, !names.isEmpty else { reply(["error": "缺少 project 或 names"]); return }
        let fileName = req["file"] as? String ?? ".env"
        guard !fileName.contains(".."), !fileName.hasPrefix("/") else { reply(["error": "只能写项目目录里的文件"]); return }
        let ms = EnvMatcher.match(names: names, items: Array(store.items.values), folders: store.folders, bindings: store.bindings[project] ?? [:])
        let usable = ms.filter { !$0.candidates.isEmpty }
        guard !usable.isEmpty else { reply(["ok": true, "written": [], "missing": names, "note": "留存里没有找到这些配置"]); return }
        var choices: [String: String] = [:]
        for m in usable { if let b = m.best { choices[m.name] = b.itemId } }
        var warn: String?
        if EnvMatcher.envIgnored(project: project, file: fileName) == false { warn = "注意：\(fileName) 没有写进 .gitignore，提交代码时可能把密钥带上去。" }
        let missing = ms.filter { $0.candidates.isEmpty }.map(\.name)
        let a = Approval(kind: .env, agent: agent, title: "写入 \(fileName)",
                         lines: ["项目：\((project as NSString).abbreviatingWithTildeInPath)", "值由手边直接写进文件，不经过对话。" + (missing.isEmpty ? "" : "没找到：" + missing.joined(separator: "、"))],
                         warning: warn, matches: usable, choices: choices) { [weak self] allow, chosen in
            guard let self, allow else { reply(["error": "用户拒绝了"]); return }
            var values: [(String, String)] = []
            var skipped: [String] = []
            for m in usable {
                guard let id = chosen[m.name], let c = m.candidates.first(where: { $0.itemId == id }) else { skipped.append(m.name); continue }
                values.append((m.name, c.value))
                self.store.bind(project: project, name: m.name, itemId: id) // 记住这个项目用哪条，下次不再问
                self.store.recordUse(id, app: nil)
            }
            let path = (project as NSString).appendingPathComponent(fileName)
            let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            do {
                try EnvMatcher.mergeEnv(existing: existing, values: values).write(toFile: path, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                reply(["ok": true, "written": values.map(\.0), "missing": missing + skipped, "file": path])
            } catch { reply(["error": "写文件失败：\(error.localizedDescription)"]) }
        }
        present(a)
    }

    private func secretGet(_ req: [String: Any], agent: String, _ reply: @escaping ([String: Any]) -> Void) {
        var item: Item?
        if let id = req["id"] as? String { item = store.items[id] }
        if item == nil, let q = req["q"] as? String {
            item = search(q, limit: 8).first { it in FieldParser.parse(it.text, loose: it.kind == .kept, ignoring: it.notSecret).contains { $0.kind == .secret } }
        }
        guard let it = item else { reply(["error": "没找到对应的留存"]); return }
        let secrets = FieldParser.parse(it.text, loose: it.kind == .kept, ignoring: it.notSecret).filter { $0.kind == .secret }
        guard let sec = secrets.first else { reply(["error": "这条里没有密钥"]); return }
        let purpose = req["purpose"] as? String ?? "没有说明用途"
        let inject = req["mode"] as? String == "inject"
        let a = Approval(kind: .secret, agent: agent, title: "要用密钥：\(SecretDetector.mask(it.displayTitle, loose: it.kind == .kept, ignoring: it.notSecret))",
                         lines: ["\(model.folderName(it.folderId).isEmpty ? "" : model.folderName(it.folderId) + " › ")\(sec.label) \(SecretDetector.maskValue(sec.value))", "用途：\(purpose)"],
                         warning: inject ? nil : "这次会把密钥原文交给 \(agent)，它会出现在对话里。") { [weak self] allow, _ in
            guard allow else { reply(["error": "用户拒绝了"]); return }
            self?.store.recordUse(it.id, app: nil)
            reply(["ok": true, "value": sec.value])
        }
        present(a)
    }

    private func saveNote(_ req: [String: Any], agent: String, _ reply: @escaping ([String: Any]) -> Void) {
        guard let text = req["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { reply(["error": "内容是空的"]); return }
        let title = req["title"] as? String ?? ""
        let folder = req["folder"] as? String ?? ""
        let a = Approval(kind: .save, agent: agent, title: "存一条到留存：\(title.isEmpty ? (Text.firstLine(text, max: 30) ?? "") : title)",
                         lines: [Text.truncate(SecretDetector.mask(text, loose: true), 200), folder.isEmpty ? "放到：未归类" : "放到：\(folder)"]) { [weak self] allow, _ in
            guard let self, allow else { reply(["error": "用户拒绝了"]); return }
            var it = Item(kind: .kept, text: text, sourceApp: agent, origin: .agent, hash: self.store.vault.fingerprint(Data(text.utf8)))
            it.title = title
            if !folder.isEmpty { it.folderId = self.store.folder(named: folder).id }
            let secrets = SecretDetector.find(in: text, loose: true)
            it.sensitive = !secrets.isEmpty
            it.ctype = secrets.isEmpty ? Classifier.classify(text) : .credential
            self.store.save(it)
            self.model.rebuild()
            if it.folderId == nil { self.model.organizer.autoFile(it.id) }
            reply(["ok": true, "id": it.id])
        }
        present(a)
    }

    private func hook(_ req: [String: Any], _ reply: @escaping ([String: Any]) -> Void) {
        let payload = req["payload"] as? [String: Any] ?? [:]
        let agent = req["agent"] as? String ?? "claude"
        model.rail.handleHook(agent: agent, payload: payload, host: req["host"] as? String)
        // 在侧栏里批准工具调用：默认关。开着时最多等 50 秒，没点就交回给 Agent 自己的确认框
        if payload["hook_event_name"] as? String == "PermissionRequest", store.settings.sidebarApprove {
            let tool = payload["tool_name"] as? String ?? "工具"
            let cwd = payload["cwd"] as? String ?? ""
            let a = Approval(kind: .tool, agent: "Claude Code", title: "要执行：\(tool)",
                             lines: [AgentScanner.brief(tool: tool, input: payload["tool_input"] as? [String: Any]), "项目：\((cwd as NSString).lastPathComponent)"]) { allow, chosen in
                // 你点了拒绝才真的拒绝；没点（超时）就交回给 Agent 自己的确认框
                reply(["decision": allow ? "allow" : (chosen["@timeout"] != nil ? "none" : "deny")])
            }
            present(a)
            return
        }
        reply(["ok": true])
    }
}
