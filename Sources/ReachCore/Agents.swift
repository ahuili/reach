import Foundation

public enum AgentKind: String, Codable {
    case claude, codex, dsh
    public var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .dsh: return "DeepSeek Harness"
        }
    }
}

public enum AgentState: String, Codable {
    case running      // 正在干活
    case waiting      // 确定在等你（来自钩子）
    case maybeWaiting // 卡在一步工具调用上有一会儿了，可能在等你确认
    case done         // 这一轮结束了
    case idle
}

public struct AgentSession: Identifiable, Equatable {
    public var id: String
    public var agent: AgentKind
    public var title: String
    public var cwd: String
    public var state: AgentState
    /// 正在做的那一步，或等待的原因
    public var detail: String
    /// 这一轮最后给出的结论
    public var lastMessage: String
    public var updatedAt: Date
    /// 所在的 App（用来"去窗口"）
    public var hostBundle: String?
    public var quota: String?
    public var transcript: String?

    public var project: String {
        cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
    }

    public init(id: String, agent: AgentKind, title: String = "", cwd: String = "", state: AgentState = .idle, detail: String = "",
                lastMessage: String = "", updatedAt: Date = Date(), hostBundle: String? = nil) {
        self.id = id; self.agent = agent; self.title = title; self.cwd = cwd; self.state = state; self.detail = detail
        self.lastMessage = lastMessage; self.updatedAt = updatedAt; self.hostBundle = hostBundle
    }
}

/// 读各个 Agent 在本机留下的会话记录，得出"在跑 / 等你 / 完成"。不需要改任何 Agent 的配置。
public enum AgentScanner {
    static func tail(_ url: URL, bytes: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), let s = String(data: d, encoding: .utf8) ?? String(data: d.dropFirst(3), encoding: .utf8) else { return [] }
        var lines = s.components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() } // 第一行可能是半截
        return lines.filter { !$0.isEmpty }
    }

    static func head(_ url: URL, bytes: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: bytes), let s = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self) as String? else { return [] }
        return s.components(separatedBy: "\n")
    }

    static func json(_ line: String) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func recentFiles(under dir: URL, ext: String, within: TimeInterval, limit: Int, now: Date) -> [(URL, Date)] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Date)] = []
        for case let u as URL in e {
            guard u.pathExtension == ext || u.lastPathComponent.hasSuffix(ext) else { continue }
            guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if now.timeIntervalSince(m) < within { out.append((u, m)) }
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(limit))
    }

    public static func brief(tool: String, input: [String: Any]?) -> String {
        let i = input ?? [:]
        let arg = (i["command"] as? String) ?? (i["file_path"] as? String) ?? (i["path"] as? String) ?? (i["pattern"] as? String)
            ?? (i["description"] as? String) ?? (i["query"] as? String) ?? (i["url"] as? String) ?? ""
        let a = Text.firstLine(arg, max: 60) ?? ""
        return a.isEmpty ? tool : "\(tool)：\(a)"
    }

    // MARK: Claude Code

    public static func parseClaude(_ url: URL, mtime: Date, now: Date = Date()) -> AgentSession? {
        let lines = tail(url, bytes: 400_000)
        guard !lines.isEmpty else { return nil }
        var s = AgentSession(id: url.deletingPathExtension().lastPathComponent, agent: .claude, updatedAt: mtime)
        s.transcript = url.path
        var lastRole = "", lastStop: String? = nil, pendingTool: String? = nil, lastText = "", lastPrompt = "", entry = ""
        var sawSubstantive = false
        for l in lines {
            // 大行（整包请求）跳过，只看对话
            guard l.count < 300_000, let o = json(l), let type = o["type"] as? String else { continue }
            if let c = o["cwd"] as? String, !c.isEmpty { s.cwd = c }
            if let e = o["entrypoint"] as? String { entry = e }
            switch type {
            case "custom-title": if let t = o["customTitle"] as? String { s.title = t }
            case "last-prompt": if let t = o["lastPrompt"] as? String { lastPrompt = t }
            case "user":
                if o["isSidechain"] as? Bool == true { continue }
                guard let m = o["message"] as? [String: Any] else { continue }
                sawSubstantive = true
                if let str = m["content"] as? String {
                    lastRole = "user"; pendingTool = nil
                    if !str.hasPrefix("<") { lastPrompt = str }
                } else if let arr = m["content"] as? [[String: Any]] {
                    if arr.contains(where: { $0["type"] as? String == "tool_result" }) { lastRole = "tool_result"; pendingTool = nil }
                    else {
                        lastRole = "user"; pendingTool = nil
                        if let t = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String, !t.hasPrefix("<") { lastPrompt = t }
                    }
                }
            case "assistant":
                if o["isSidechain"] as? Bool == true { continue }
                guard let m = o["message"] as? [String: Any], let arr = m["content"] as? [[String: Any]] else { continue }
                sawSubstantive = true
                lastRole = "assistant"
                lastStop = m["stop_reason"] as? String
                for b in arr {
                    switch b["type"] as? String {
                    case "text": if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = t }
                    case "tool_use": pendingTool = brief(tool: b["name"] as? String ?? "工具", input: b["input"] as? [String: Any])
                    default: break
                    }
                }
            default: break
            }
        }
        guard sawSubstantive else { return nil }
        if s.cwd.isEmpty {
            for l in head(url, bytes: 20_000) { if let o = json(l), let c = o["cwd"] as? String, !c.isEmpty { s.cwd = c; break } }
        }
        if s.title.isEmpty { s.title = Text.firstLine(lastPrompt, max: 40) ?? "" }
        s.hostBundle = entry.lowercased().contains("desktop") ? "com.anthropic.claudefordesktop" : nil
        let age = now.timeIntervalSince(mtime)
        if lastRole == "assistant", pendingTool == nil, lastStop != "tool_use" {
            s.state = .done
            s.lastMessage = lastText
        } else if let t = pendingTool, lastRole == "assistant" {
            s.detail = t
            s.state = age < 8 ? .running : (age < 45 * 60 ? .maybeWaiting : .idle)
        } else {
            s.detail = lastRole == "user" ? "在想" : "在继续"
            s.state = age < 180 ? .running : .idle
        }
        return s
    }

    // MARK: Codex

    public static func parseCodex(_ url: URL, mtime: Date, now: Date = Date()) -> AgentSession? {
        var s = AgentSession(id: url.deletingPathExtension().lastPathComponent, agent: .codex, updatedAt: mtime)
        s.transcript = url.path
        // 第一行可能很长（带着整段系统指令），只取开头能找到的字段
        if let first = head(url, bytes: 4000).first {
            if let r = first.range(of: "\"cwd\":\"") {
                let rest = first[r.upperBound...]
                if let end = rest.firstIndex(of: "\"") { s.cwd = String(rest[..<end]) }
            }
            if first.contains("Codex Desktop") { s.hostBundle = "com.openai.codex" }
            if let r = first.range(of: "\"session_id\":\"") {
                let rest = first[r.upperBound...]
                if let end = rest.firstIndex(of: "\"") { s.id = String(rest[..<end]) }
            }
        }
        var started = false, completed = false, lastTool = "", lastUser = "", lastAgent = ""
        for l in tail(url, bytes: 400_000) {
            guard l.count < 300_000, let o = json(l), let type = o["type"] as? String else { continue }
            let p = o["payload"] as? [String: Any] ?? [:]
            let pt = p["type"] as? String ?? ""
            if type == "event_msg" {
                switch pt {
                case "task_started": started = true; completed = false; lastTool = ""
                case "task_complete":
                    completed = true
                    if let m = p["last_agent_message"] as? String { lastAgent = m }
                case "turn_aborted": completed = true
                case "token_count":
                    if let rl = p["rate_limits"] as? [String: Any], let pr = rl["primary"] as? [String: Any],
                       let used = pr["used_percent"] as? Double {
                        var q = "额度已用 \(Int(used))%"
                        if let secs = pr["resets_in_seconds"] as? Double { q += "，\(Int(secs / 60)) 分钟后重置" }
                        else if let at = pr["resets_at"] as? Double {
                            let mins = Int((Date(timeIntervalSince1970: at).timeIntervalSince(now)) / 60)
                            if mins > 0 { q += "，\(mins >= 120 ? "\(mins / 60) 小时" : "\(mins) 分钟")后重置" }
                        }
                        s.quota = q
                    }
                default: break
                }
            } else if type == "response_item" {
                switch pt {
                case "function_call", "custom_tool_call":
                    let name = p["name"] as? String ?? "工具"
                    var arg = ""
                    if let a = p["arguments"] as? String, let d = a.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                        arg = (j["command"] as? String) ?? ((j["command"] as? [String])?.joined(separator: " ")) ?? (j["path"] as? String) ?? ""
                    } else if let a = p["input"] as? String { arg = a }
                    let a = Text.firstLine(arg, max: 60) ?? ""
                    lastTool = a.isEmpty ? name : "\(name)：\(a)"
                case "message":
                    let role = p["role"] as? String
                    let txt = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if role == "user", !txt.hasPrefix("<"), !txt.isEmpty { lastUser = txt }
                    if role == "assistant", !txt.isEmpty { lastAgent = txt }
                default: break
                }
            }
        }
        s.title = Text.firstLine(lastUser, max: 40) ?? ""
        let age = now.timeIntervalSince(mtime)
        if completed || !started {
            s.state = (completed || !lastAgent.isEmpty) ? .done : .idle
            s.lastMessage = lastAgent
        } else {
            s.detail = lastTool.isEmpty ? "在想" : lastTool
            s.state = age < 30 ? .running : (age < 45 * 60 ? .maybeWaiting : .idle)
        }
        return s
    }

    // MARK: 汇总

    public static func scan(now: Date = Date(), home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentSession] {
        var out: [AgentSession] = []
        let window: TimeInterval = 6 * 3600
        for (u, m) in recentFiles(under: home.appendingPathComponent(".claude/projects"), ext: "jsonl", within: window, limit: 12, now: now) {
            if let s = parseClaude(u, mtime: m, now: now) { out.append(s) }
        }
        for (u, m) in recentFiles(under: home.appendingPathComponent(".codex/sessions"), ext: "jsonl", within: window, limit: 12, now: now) {
            if let s = parseCodex(u, mtime: m, now: now) { out.append(s) }
        }
        // DeepSeek Harness 的会话记录是压缩格式，读不出内容，只能从文件更新时间判断在不在跑
        for (u, m) in recentFiles(under: home.appendingPathComponent(".dsh/sessions"), ext: "zstd", within: 30 * 60, limit: 6, now: now) {
            let dir = u.deletingLastPathComponent()
            var s = AgentSession(id: dir.lastPathComponent, agent: .dsh, updatedAt: m, hostBundle: "com.deepseek.dsh")
            let proj = dir.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            s.cwd = "/" + proj.replacingOccurrences(of: "-", with: "/")
            s.state = now.timeIntervalSince(m) < 20 ? .running : .idle
            s.detail = s.state == .running ? "在干活（这个 Agent 看不到细节）" : ""
            if s.state == .running { out.append(s) }
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 从 Agent 的结论里拆出值得单独贴的东西：代码块和网址
    public static func outputs(from message: String) -> [(text: String, type: ContentType)] {
        var out: [(String, ContentType)] = []
        for b in Markdown.codeBlocks(message).prefix(4) where b.count < 4000 {
            out.append((b, Classifier.classify(b) == .command ? .command : .code))
        }
        let re = try! NSRegularExpression(pattern: "https?://[^\\s\"'<>）)\\]`*]+")
        let ns = message as NSString
        var seen = Set<String>()
        for m in re.matches(in: message, range: NSRange(location: 0, length: ns.length)).prefix(6) {
            let u = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:，。；"))
            if seen.insert(u).inserted, !out.contains(where: { $0.0.contains(u) }) { out.append((u, .link)) }
        }
        return Array(out.prefix(6))
    }
}
