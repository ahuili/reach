import Foundation
import ReachCore

// 手边的命令行。给 Agent 用，也给你自己用。它只是把请求转给正在运行的手边 App；
// 凡是涉及密钥的请求，都要你在侧栏里点了允许才有结果。

let env = ProcessInfo.processInfo.environment
var args = Array(CommandLine.arguments.dropFirst())

func agentName() -> String {
    if let a = env["REACH_AGENT"], !a.isEmpty { return a }
    if env["CLAUDECODE"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil { return "Claude Code" }
    if env.keys.contains(where: { $0.hasPrefix("CODEX_") }) { return "Codex" }
    return "命令行"
}

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func call(_ req: [String: Any], timeout: TimeInterval = 15) -> [String: Any] {
    var r = req
    if r["agent"] == nil { r["agent"] = agentName() }
    guard let ans = IPC.request(r, timeout: timeout) else { return ["error": "手边没有在运行（或没有回应）。请先打开手边 App。"] }
    return ans
}

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}

func absolute(_ p: String) -> String {
    let u = URL(fileURLWithPath: p, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    return u.standardizedFileURL.path
}

func pretty(_ o: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "\(o)"
}

func fail(_ r: [String: Any]) -> Never { err("✗ " + (r["error"] as? String ?? "失败")); exit(1) }

func printItems(_ r: [String: Any], withText: Bool = false) {
    guard r["error"] == nil else { fail(r) }
    let items = r["items"] as? [[String: Any]] ?? []
    if items.isEmpty { out("（没有找到）"); return }
    for it in items {
        let folder = it["folder"] as? String ?? ""
        let head = "[\(it["id"] as? String ?? "")] " + (folder.isEmpty ? "" : folder + " › ") + (it["title"] as? String ?? "")
        out(head + ((it["has_secret"] as? Bool ?? false) ? "  （含密钥）" : ""))
        let body = (withText ? it["text"] : it["preview"]) as? String ?? ""
        for l in body.split(whereSeparator: \.isNewline).prefix(withText ? 200 : 3) { out("    " + l) }
    }
}

let usage = """
手边 reach：查你留存的账号、密钥、连接信息，和最近复制的内容。

  reach search <关键词>                      搜索（密钥打码）
  reach read <id>                            读一条全文（密钥位置是占位）
  reach recent [条数]                         最近复制的内容
  reach env match NAME... [--project 目录]    这些配置名在手边里有没有对应的值
  reach env write NAME... [--project 目录] [--file .env]
                                              你批准后，把值直接写进项目的 .env
  reach run --env 变量=留存关键词 ... -- 命令   你批准后，带着密钥运行一条命令
  reach secret <关键词> [--purpose 用途]       你批准后，输出密钥原文（会进对话，尽量用上面两种）
  reach save --title 标题 [--folder 文件夹]    把标准输入的内容存进留存（要你批准）
  reach import sidenotes                     把 SideNotes 的笔记搬进留存（原件不动，重复搬不会多出一份）
  reach status                               数量和各项开关的状态（不含内容）
  reach show                                 打开侧栏
  reach mcp                                  作为 MCP 服务运行（给 Agent 配置用）
"""

func runHook() -> Never {
    // Agent 的钩子：把事件转给手边。手边没开、超时都静默放行，绝不挡住 Agent。
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { exit(0) }
    let event = payload["hook_event_name"] as? String ?? ""
    var req: [String: Any] = ["cmd": "hook", "agent": args.first ?? "claude", "payload": payload]
    if let host = env["__CFBundleIdentifier"], !host.isEmpty { req["host"] = host }
    let ans = IPC.request(req, timeout: event == "PermissionRequest" ? 55 : 2)
    if event == "PermissionRequest", let d = ans?["decision"] as? String, d == "allow" || d == "deny" {
        var decision: [String: Any] = ["behavior": d]
        if d == "deny" { decision["message"] = "用户在手边里拒绝了这一步" }
        let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let s = try? JSONSerialization.data(withJSONObject: o) { FileHandle.standardOutput.write(s) }
    }
    exit(0)
}

// MARK: MCP（stdio，JSON-RPC）

let tools: [[String: Any]] = [
    ["name": "search", "description": "搜索用户在手边里留存的账号、服务器、后台入口、API Key 等，以及最近复制的内容。密钥以打码形式返回。需要连接信息或凭据时先用它，不要向用户索要。",
     "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "description": "关键词，空格分隔表示都要包含"], "limit": ["type": "integer"]], "required": ["query"]]],
    ["name": "read", "description": "按 id 读一条的全文。密钥位置是占位，不会给出原文。",
     "inputSchema": ["type": "object", "properties": ["id": ["type": "string"]], "required": ["id"]]],
    ["name": "recent_clips", "description": "用户最近复制的几条内容（用户说「我刚复制的那段」时用）。",
     "inputSchema": ["type": "object", "properties": ["n": ["type": "integer"]]]],
    ["name": "match_env", "description": "给出项目需要的环境变量名，返回手边里哪些有对应的值（已匹配 / 有多个候选 / 没有）。不返回值本身。",
     "inputSchema": ["type": "object", "properties": ["names": ["type": "array", "items": ["type": "string"]], "project": ["type": "string", "description": "项目目录的绝对路径"]], "required": ["names", "project"]]],
    ["name": "write_env", "description": "请用户批准后，由手边把这些环境变量的值直接写进项目的 .env 文件。值不经过对话。有多个候选时由用户在侧栏里选。",
     "inputSchema": ["type": "object", "properties": ["names": ["type": "array", "items": ["type": "string"]], "project": ["type": "string"], "file": ["type": "string", "description": "默认 .env"]], "required": ["names", "project"]]],
    ["name": "request_secret", "description": "请用户批准后取得一个密钥的原文。原文会进入对话，只有 write_env 和命令行 `reach run` 都不适用时才用。必须说明用途。",
     "inputSchema": ["type": "object", "properties": ["query": ["type": "string", "description": "留存的关键词或 id"], "purpose": ["type": "string"]], "required": ["query", "purpose"]]],
    ["name": "save_note", "description": "把新建的账号、Token、连接信息存回用户的手边（要用户批准）。",
     "inputSchema": ["type": "object", "properties": ["title": ["type": "string"], "text": ["type": "string"], "folder": ["type": "string"]], "required": ["title", "text"]]],
]

func mcpCall(_ name: String, _ a: [String: Any]) -> (String, Bool) {
    var r: [String: Any]
    switch name {
    case "search": r = call(["cmd": "search", "q": a["query"] as? String ?? "", "limit": a["limit"] as? Int ?? 10])
    case "read": r = call(["cmd": "read", "id": a["id"] as? String ?? ""])
    case "recent_clips": r = call(["cmd": "recent", "n": a["n"] as? Int ?? 5])
    case "match_env": r = call(["cmd": "env.match", "names": a["names"] as? [String] ?? [], "project": a["project"] as? String ?? ""])
    case "write_env":
        var q: [String: Any] = ["cmd": "env.write", "names": a["names"] as? [String] ?? [], "project": a["project"] as? String ?? ""]
        if let f = a["file"] as? String { q["file"] = f }
        r = call(q, timeout: 170)
    case "request_secret":
        let q = a["query"] as? String ?? ""
        r = call(["cmd": "secret.get", "q": q, "id": q, "purpose": a["purpose"] as? String ?? ""], timeout: 170)
    case "save_note": r = call(["cmd": "save", "title": a["title"] as? String ?? "", "text": a["text"] as? String ?? "", "folder": a["folder"] as? String ?? ""], timeout: 170)
    default: return ("没有这个工具：\(name)", true)
    }
    if let e = r["error"] as? String { return (e, true) }
    r["ok"] = nil
    return (pretty(r), false)
}

func runMCP() -> Never {
    func send(_ o: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        FileHandle.standardOutput.write(d)
    }
    while let line = readLine(strippingNewline: true) {
        guard let d = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let method = msg["method"] as? String else { continue }
        guard let id = msg["id"] else { continue } // 通知不用回
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            send(["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "reach", "version": "0.1.0"],
                "instructions": "手边是用户本机的账号、密钥、连接信息和复制历史。需要这些时先查这里。密钥从不直接给出：用 write_env 让手边写进 .env，或让用户批准 request_secret。"]])
        case "ping": send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        case "tools/list": send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
        case "tools/call":
            let (text, isErr) = mcpCall(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
            send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": isErr]])
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "不支持的方法：\(method)"]])
        }
    }
    exit(0)
}

// MARK: 入口

guard let cmd = args.first else { out(usage); exit(0) }
args.removeFirst()

switch cmd {
case "hook": runHook()
case "mcp": runMCP()
case "show": _ = call(["cmd": "show"]); exit(0)
case "ping":
    let r = call(["cmd": "ping"])
    if r["error"] != nil { fail(r) }
    out("手边在运行")
case "status":
    let r = call(["cmd": "status"])
    if r["error"] != nil { fail(r) }
    func yes(_ k: String) -> String { (r[k] as? Bool ?? false) ? "是" : "否" }
    out("最近复制 \(r["clips"] ?? 0) 条，留存 \(r["kept"] ?? 0) 条（\(r["folders"] ?? 0) 个文件夹），其中含密钥 \(r["sensitive"] ?? 0) 条")
    out("快捷键 ⇧⌘V 注册成功：\(yes("hotkey"))；⌃⌥V：\(yes("hotkey2"))")
    out("自动粘贴（辅助功能权限）：\(yes("autopaste"))；暂停记录：\(yes("paused"))")
    out("看到的 Agent 会话：\(r["agents"] ?? 0)；已连接 Claude Code：\(yes("claude"))，Codex：\(yes("codex"))，命令行已安装：\(yes("cli"))")
    out("开机自动打开：\(yes("login"))")
case "import":
    guard args.first == "sidenotes" else { err("用法：reach import sidenotes"); exit(2) }
    let r = call(["cmd": "import.sidenotes"], timeout: 60)
    if r["error"] != nil { fail(r) }
    out("搬过来 \(r["notes"] ?? 0) 条、\(r["folders"] ?? 0) 个文件夹，其中 \(r["with_secrets"] ?? 0) 条含密钥（已打码）；跳过 \(r["skipped"] ?? 0) 条（空的、示例或已经搬过的）")
case "search":
    guard !args.isEmpty else { err("用法：reach search <关键词>"); exit(2) }
    printItems(call(["cmd": "search", "q": args.joined(separator: " "), "limit": 12]))
case "recent":
    printItems(call(["cmd": "recent", "n": Int(args.first ?? "5") ?? 5]), withText: true)
case "read":
    guard let id = args.first else { err("用法：reach read <id>"); exit(2) }
    let r = call(["cmd": "read", "id": id])
    guard let it = r["item"] as? [String: Any] else { fail(r) }
    out(it["text"] as? String ?? "")
    if let n = it["note"] as? String { err("（" + n + "）") }
case "env":
    guard let sub = args.first, sub == "match" || sub == "write" else { err("用法：reach env match|write NAME... [--project 目录]"); exit(2) }
    args.removeFirst()
    let project = absolute(take("--project") ?? ".")
    let file = take("--file")
    guard !args.isEmpty else { err("至少给一个配置名"); exit(2) }
    if sub == "match" {
        let r = call(["cmd": "env.match", "names": args, "project": project])
        guard let ms = r["matches"] as? [[String: Any]] else { fail(r) }
        for m in ms {
            let st = m["status"] as? String ?? ""
            let cs = (m["candidates"] as? [[String: Any]] ?? []).map { "\($0["title"] as? String ?? "") \($0["masked"] as? String ?? "")" }
            let label = st == "matched" ? "已匹配" : (st == "ambiguous" ? "有 \(cs.count) 个候选，写入时由用户选" : "没有")
            out("\(m["name"] as? String ?? "")：\(label)" + (cs.isEmpty ? "" : "  → " + cs.joined(separator: "；")))
        }
    } else {
        var q: [String: Any] = ["cmd": "env.write", "names": args, "project": project]
        if let f = file { q["file"] = f }
        err("等你在手边里批准…")
        let r = call(q, timeout: 170)
        if r["error"] != nil { fail(r) }
        let written = r["written"] as? [String] ?? [], missing = r["missing"] as? [String] ?? []
        if !written.isEmpty { out("已写入 \(r["file"] as? String ?? ".env")：" + written.joined(separator: "、")) }
        if !missing.isEmpty { out("没有写（手边里没有，或用户没选）：" + missing.joined(separator: "、")) }
    }
case "secret":
    let purpose = take("--purpose") ?? "没有说明用途"
    guard !args.isEmpty else { err("用法：reach secret <关键词> [--purpose 用途]"); exit(2) }
    err("等你在手边里批准…")
    let q = args.joined(separator: " ")
    let r = call(["cmd": "secret.get", "q": q, "id": q, "purpose": purpose], timeout: 170)
    guard let v = r["value"] as? String else { fail(r) }
    out(v)
case "run":
    var pairs: [(String, String)] = []
    while let e = take("--env") {
        guard let eq = e.firstIndex(of: "=") else { err("--env 的写法是 变量=留存关键词"); exit(2) }
        pairs.append((String(e[..<eq]), String(e[e.index(after: eq)...])))
    }
    guard let sep = args.firstIndex(of: "--"), sep + 1 < args.count, !pairs.isEmpty else {
        err("用法：reach run --env 变量=留存关键词 [--env ...] -- 命令 参数…"); exit(2)
    }
    let command = Array(args[(sep + 1)...])
    err("等你在手边里批准…")
    for (name, query) in pairs {
        let r = call(["cmd": "secret.get", "q": query, "id": query, "mode": "inject",
                      "purpose": "运行：" + command.joined(separator: " ").prefix(80)], timeout: 170)
        guard let v = r["value"] as? String else { fail(r) }
        setenv(name, v, 1)
    }
    // 换成要运行的命令：密钥只在它的环境变量里，不打印、不回到对话
    let cargs = command.map { strdup($0) } + [nil]
    execvp(command[0], cargs)
    err("✗ 运行不了：\(command[0])"); exit(127)
case "save":
    let title = take("--title") ?? ""
    let folder = take("--folder") ?? ""
    let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    err("等你在手边里批准…")
    let r = call(["cmd": "save", "title": title, "text": text, "folder": folder], timeout: 170)
    if r["error"] != nil { fail(r) }
    out("已存进手边")
case "help", "-h", "--help": out(usage)
default: err("不认识的命令：\(cmd)\n\n" + usage); exit(2)
}
