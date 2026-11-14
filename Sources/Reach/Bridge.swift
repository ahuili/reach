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
    weak var shot: ShotController?

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
                   "hotkey": app?.hotkeyOK ?? false, "hotkey2": app?.hotkey2OK ?? false, "shotkey": app?.shotHotkeyOK ?? false, "shotlabel": model.settings.shotKey.label, "panellabel": model.settings.panelKey.label, "screen": ShotGrab.allowed, "autopaste": Keys.trusted,
                   "paused": store.settings.paused, 
                   "cli": Connect.cliInstalled, "ai": store.settings.ai.isReady ? store.settings.ai.model : "", "login": LoginItem.enabled,
                   "links": store.settings.links.enabled, "linksPaused": store.settings.links.paused, "linksDefault": LinkRouter.isDefault, "linkRules": store.settings.links.rules.count])
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
            if let id = req["select"] as? String { model.selection = id }
            if let t = req["target"] as? String { model.targetBundle = t; model.targetName = req["targetName"] as? String ?? t; model.rebuild() }
            if req["options"] as? Bool == true { model.openOptions() } else if req["options"] as? Bool == false { model.options = nil }
            if req["edit"] as? Bool == true, let it = model.selectedItem { model.edit(it) } else if req["edit"] as? Bool == false { model.editor = nil }
            if let ids = req["basket"] as? [String] { model.basket = ids }
            if testMode {
                if let ai = req["ai"] as? [String: Any] {
                    if let v = ai["baseURL"] as? String { model.settings.ai.baseURL = v }
                    if let v = ai["model"] as? String { model.settings.ai.model = v }
                    if let v = ai["vision"] as? Bool { model.settings.ai.vision = v }
                    if let v = ai["enabled"] as? Bool { model.settings.ai.enabled = v }
                }
                if req["save"] as? Bool == true { model.startSave(model.selectedItem) } else if req["save"] as? Bool == false { model.saving = nil }
                if let q = req["saveQuery"] as? String {
                    model.saving?.query = q
                    // 和打字一样：有字就选中第一条搜到的
                    model.saving?.index = q.isEmpty ? 0 : (model.saveChoices.firstIndex { if case .append = $0 { return true }; return false } ?? 0)
                }
                if req["saveChoose"] as? Bool == true, let s = model.saving, model.saveChoices.indices.contains(s.index) { model.finishSave(model.saveChoices[s.index]) }
                if let b = req["reveal"] as? Bool, let it = model.selectedItem {
                    if b { model.revealed.insert(it.id) } else { model.revealed.remove(it.id) }
                    if model.options != nil { model.openOptions() }
                }
            }
            if let id = req["activate"] as? String, let it = store.items[id] { model.paster.paste(it, mode: .smart) }
            if let n = req["approve"] as? Int, model.approvals.indices.contains(n) { model.resolve(model.approvals[n], allow: req["allow"] as? Bool ?? true) }
            app?.panelController.show(.approval)
            if testMode, req["focus"] as? Bool == true { app?.panelController.panel.makeKey() }
            reply(["ok": true, "rows": model.rows.map(\.id).count, "approvals": model.approvals.map(\.title), "confirm": model.confirmSecret != nil,
                   "options": (model.options ?? []).map { $0.label + " " + $0.detail },
                   "saving": model.saveChoices.map { c -> String in
                       switch c { case .new: return "new"; case .each: return "each"; case .append(let id): return "append:" + (store.items[id]?.displayTitle ?? "") }
                   }, "saveIndex": model.saving?.index ?? -1, "key": app?.panelController.panel.isKeyWindow ?? false,
                   "responder": app?.panelController.panel.firstResponder.map { String(describing: type(of: $0)) } ?? ""])
        case "debug.link":
            // 链接分流的测试入口：只在测试模式里能改设置、塞历史；判断结果只回去处，不开浏览器
            guard let links = app?.links else { reply(["error": "no links"]); return }
            if testMode {
                if let b = req["enable"] as? Bool { model.settings.links.enabled = b }
                if let u = req["unknown"] as? String, let m = LinkUnknown(rawValue: u) { model.settings.links.unknown = m }
                if req["reset"] as? Bool == true { model.settings.links.rules = []; model.settings.links.streaks = [:] }
                var vs: [String: SiteVisits]?
                if let v = req["visits"] as? [String: [String: Int]] {
                    vs = v.mapValues { counts in
                        var sv = SiteVisits(); var t = 0.0
                        // 次数少的先加，最近几次落在次数最多的账号上
                        for (k, n) in counts.sorted(by: { $0.value < $1.value }) { for _ in 0..<n { t += 1; sv.add(k, at: t) } }
                        return sv
                    }
                }
                links.debugSet(visits: vs, domains: req["domains"] as? [String: String], groups: req["groups"] as? [String: [String]])
            }
            var out: [String: Any] = ["ok": true]
            if let s = req["url"] as? String, let u = URL(string: s) {
                let src = req["source"] as? String
                if testMode, let i = req["pick"] as? Int {
                    let r = LinkPicker.Remember(rawValue: req["remember"] as? String ?? "once") ?? .once
                    out["picked"] = links.debugChoose(u, index: i, remember: r, source: src)?.key ?? ""
                } else if testMode, req["handle"] as? Bool == true {
                    links.handle(u, source: src, sourceName: src, option: false)
                    out["opened"] = links.testLog.last?["target"] ?? ""
                }
                let d = links.decide(u, source: src)
                out["kind"] = d.kind.rawValue; out["url"] = d.url.absoluteString; out["target"] = d.target?.key ?? ""
                out["ranked"] = d.ranked.prefix(6).map(\.target.key)
            }
            if let u = (req["snapURL"] as? String).flatMap(URL.init(string:)) { links.debugSnap(u, picker: req["pickerSnap"] as? String, notice: req["noticeSnap"] as? String) }
            out["hosts"] = links.visits.count; out["loadMS"] = links.loadMS
            out["rules"] = model.settings.links.rules.map { "\($0.site ?? "*")|\($0.source ?? "*")>\($0.target.key)" }
            out["dests"] = links.destinations().map { "\($0.target.key)=\($0.title)" }
            reply(out)
        case "debug.shot":
            // 截图界面的测试入口：拿一张图当冻住的屏幕，不需要屏幕录制权限
            guard let shot else { reply(["error": "no shot"]); return }
            func img(_ k: String) -> CGImage? { (req[k] as? String).flatMap { NSImage(contentsOfFile: $0) }?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            if let i = img("fake") { shot.close(reactivate: false); shot.openFake(i) }
            if let i = img("annotate") { shot.close(reactivate: false); shot.annotate(image: i, sourceName: "截图", bundle: nil) }
            if let r = req["select"] as? [Double], r.count == 4 { shot.fakeSelect(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) }
            if let t = req["tool"] as? String { shot.debugTool(t) }
            if let h = req["hint"] as? String { shot.debugHint(h.isEmpty ? nil : h) }
            if let r = req["reselect"] as? [Double], r.count == 4 { shot.debugReselect(CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) }
            if let m = req["mark"] as? [String: Any], let t = ShotTool(rawValue: m["tool"] as? String ?? ""), let r = m["rect"] as? [Double], r.count == 4 {
                let k = shot.debugPixel
                let rect = CGRect(x: r[0] * k, y: r[1] * k, width: r[2] * k, height: r[3] * k)
                var mk = ShotMark(tool: t, rect: rect, color: ShotSession.colors[m["color"] as? Int ?? 0], width: (t == .text ? 18 : t == .mosaic ? 9 : 3) * k)
                if t == .arrow { mk.points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)] }
                if t == .step { mk.number = m["number"] as? Int ?? 1 }
                mk.text = m["text"] as? String ?? ""
                shot.debugMark(mk)
            }
            if let a = req["act"] as? String {
                switch a {
                case "copy": shot.act(.copy); case "basket": shot.act(.basket); case "pin": shot.act(.pin)
                case "cancel": shot.act(.cancel); case "redact": shot.act(.toggleRedact); case "undo": shot.act(.undo)
                case "translate": shot.act(.translate); case "explain": shot.act(.explain)
                case "copyAnswer": shot.act(.copyAnswer); case "keepAnswer": shot.act(.keepAnswer)
                default: if a.hasPrefix("ask:") { shot.act(.ask(String(a.dropFirst(4)))) }
                }
            }
            if let p = req["snap"] as? String { _ = shot.snapshot(to: p) }
            reply(shot.debugState().merging(["ok": true]) { a, _ in a })
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
        guard !usable.isEmpty else { reply(["ok": true, "written": [], "missing": names, "note": "抽屉里没有找到这些配置"]); return }
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
        guard let it = item else { reply(["error": "抽屉里没找到对应的那条"]); return }
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
        let a = Approval(kind: .save, agent: agent, title: "存一条到抽屉：\(title.isEmpty ? (Text.firstLine(text, max: 30) ?? "") : title)",
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

    /// 旧版装过的 Claude Code 钩子还会打过来：什么都不做，直接放行
    private func hook(_ req: [String: Any], _ reply: @escaping ([String: Any]) -> Void) { reply(["ok": true]) }
}
