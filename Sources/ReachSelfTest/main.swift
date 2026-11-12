import Foundation
import ReachCore
import SQLite3

// 自测：CommandLineTools 没有 XCTest，用这个可执行文件代替。数据放在临时目录，不碰真实数据。
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reach-selftest-\(UUID().uuidString)")
setenv("REACH_HOME", tmp.path, 1)
setenv("REACH_KEYFILE", "1", 1)

var passed = 0, failed = 0
func check(_ cond: @autoclosure () -> Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond() { passed += 1 } else { failed += 1; print("✗ \(name)  (\((file as NSString).lastPathComponent):\(line))") }
}

// 密钥识别
let fake = "sk-" + String(repeating: "aB3dE6", count: 6)
check(SecretDetector.isWholeSecret(fake), "整段是 Key")
check(!SecretDetector.isWholeSecret("hello world"), "普通文字不是密钥")
check(!SecretDetector.isWholeSecret("https://example.com/path"), "网址不是密钥")
let note = "测试后台 https://staging.example.com/admin\n账号 admin@example.com\n密码 Passw0rd!x\nkey: \(fake)"
let spans = SecretDetector.find(in: note, loose: true)
check(spans.count == 2, "笔记里认出 2 个密钥（实际 \(spans.count)：\(spans.map(\.value))）")
check(spans.contains { $0.value == "Passw0rd!x" }, "认出密码")
check(spans.contains { $0.value == fake }, "认出 Key")
let masked = SecretDetector.mask(note, loose: true)
check(!masked.contains("Passw0rd!x") && !masked.contains(fake) && masked.contains("admin@example.com"), "打码后看不到密钥，账号还在")
check(SecretDetector.redact(note).contains("[密码]"), "发给模型前换成占位")
check(SecretDetector.find(in: "版本 v1.2.3 路径 /usr/local/bin 提交 3f2a9c1d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39", loose: true).isEmpty, "版本号、路径、提交号不误认")
check(SecretDetector.find(in: "postgres://report:S3cretPw@10.0.3.21:5432/app").contains { $0.value == "S3cretPw" }, "连接串里的密码")
check(SecretDetector.find(in: "修改密码功能已经上线了").isEmpty && SecretDetector.find(in: "忘记密码怎么办呢", loose: true).isEmpty, "带「密码」两个字的句子不算密钥")
check(SecretDetector.find(in: "the password reset flow is broken").isEmpty, "password reset 不算")
check(SecretDetector.find(in: "password: hunter2go").count == 1, "有冒号的照认")
check(SecretDetector.find(in: "id 3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f pod report-api-7d9f8b6c5-x2k4q file MyReport2026Final_v2.docx").isEmpty, "UUID、容器名、文件名不算密钥")
check(SecretDetector.find(in: "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY").count == 1, "长的随机串照认")

check(SecretDetector.mask(note, loose: true, ignoring: ["Passw0rd!x"]).contains("Passw0rd!x"), "标记为不是密钥后不打码")

// 字段
let fields = FieldParser.parse(note)
check(fields.first { $0.kind == .url }?.value == "https://staging.example.com/admin", "拆出网址")
check(fields.first { $0.kind == .account }?.value == "admin@example.com", "拆出账号")
check(fields.filter { $0.kind == .secret }.count == 2, "拆出两个密钥字段")
check(FieldParser.parse("ssh deploy@10.0.3.21 -p 2222").contains { $0.kind == .command }, "拆出命令")

// 分类
check(Classifier.classify("https://example.com/a?b=1") == .link, "链接")
check(Classifier.classify("git status") == .command, "命令")
check(Classifier.classify("$ npm install\n$ npm run build") == .command, "多行命令")
check(Classifier.classify("{\"a\": 1, \"b\": [2]}") == .json, "JSON")
check(Classifier.classify(note) == .credential, "账号密码")
check(Classifier.classify("Traceback (most recent call last):\n  File \"a.py\", line 1\nValueError: bad") == .error, "报错")
check(Classifier.classify("姓名\t部门\n张三\t销售\n李四\t研发") == .table, "表格")
check(Classifier.classify("func main() {\n    print(1)\n}\n") == .code, "代码")
check(Classifier.classify("明天下午三点开会，记得带电脑") == .text, "普通文字")
check(Classifier.classify(fake) == .secret, "密钥")

// Markdown
let md = "## 结论\n\n**部署成功**，地址见 [后台](https://a.example.com)。\n\n- 第一步：`make build`\n- [x] 已验证\n\n| 项 | 值 |\n|---|---|\n| 版本 | 1.8 |\n\n```bash\nmake deploy\n```"
check(Markdown.looksMarkdown(md), "认出 Markdown")
check(!Markdown.looksMarkdown("就是一句普通的话，没有任何记号。\n第二行。"), "普通文字不算 Markdown")
let plain = Markdown.toPlain(md)
check(!plain.contains("**") && !plain.contains("##") && !plain.contains("```") && !plain.contains("|---"), "去掉记号：\(plain)")
check(plain.contains("部署成功") && plain.contains("• 第一步：make build") && plain.contains("☑ 已验证") && plain.contains("后台（https://a.example.com）") && plain.contains("版本 ｜ 1.8") && plain.contains("make deploy"), "内容都还在")
let html = Markdown.toHTML(md)
check(html.contains("<h2>结论</h2>") && html.contains("<b>部署成功</b>") && html.contains("<li>") && html.contains("<table") && html.contains("<pre"), "转成 HTML")
check(Markdown.forTerminal("$ make build\n$ make deploy\n") == "make build\nmake deploy", "终端：去掉提示符和结尾换行")
check(Markdown.codeBlocks(md) == ["make deploy"], "取代码块")

// 模板
check(Template.slots(in: "把{内容}翻成英文，语气{正式/随意}").map(\.name) == ["内容", "正式/随意"], "认出空位")
check(Template.slots(in: "{\"a\": 1}").isEmpty, "JSON 不算空位")
check(Template.fill("你好{名字}", values: ["名字": "张三"]) == "你好张三", "填空位")

// 加密存储
do {
    let vault = try Vault.open()
    let store = try Store(vault: vault)
    var a = Item(kind: .kept, text: note, hash: vault.fingerprint(Data(note.utf8)))
    a.title = "测试后台"
    store.save(a)
    var c = Item(kind: .clip, text: "临时内容", hash: "h2")
    c.expiresAt = Date().addingTimeInterval(-10)
    store.save(c)
    var common = Item(kind: .clip, text: "常用命令", hash: "h3")
    common.expiresAt = Date().addingTimeInterval(-10); common.useCount = 5; common.lastUsedAt = Date()
    store.save(common)
    store.settings.paused = true
    let f = store.folder(named: "公司 A")
    check(store.folder(named: "公司 A").id == f.id, "同名文件夹不重复建")

    let raw = try Data(contentsOf: ReachPaths.db)
    check(raw.range(of: Data("Passw0rd!x".utf8)) == nil && raw.range(of: Data("测试后台".utf8)) == nil && raw.range(of: Data(fake.utf8)) == nil,
          "库文件里搜不到明文")
    let wal = (try? Data(contentsOf: URL(fileURLWithPath: ReachPaths.db.path + "-wal"))) ?? Data()
    check(wal.range(of: Data("Passw0rd!x".utf8)) == nil, "日志文件里也搜不到明文")

    let again = try Store(vault: vault)
    check(again.items[a.id]?.text == note, "重新打开能读回")
    check(again.settings.paused == true, "设置能存住")
    check(again.purgeExpired() == 1, "过期的清掉，常用的留下")
    check(again.items[common.id] != nil && again.items[c.id] == nil, "清的是对的那条")
    again.recordUse(a.id, app: "org.tabby")
    check(again.items[a.id]?.useByApp["org.tabby"] == 1, "记录在哪贴过")
    let wrong = try? Store(vault: Vault(key: .init(size: .bits256)))
    check(wrong?.items.isEmpty == true, "换一把钥匙读不出任何内容")

    // 配置匹配
    var k1 = Item(kind: .kept, text: "百炼 公司 \(fake)", hash: "k1"); k1.title = "百炼 公司"
    var k2 = Item(kind: .kept, text: "百炼 个人 sk-" + String(repeating: "Zz9", count: 10), hash: "k2"); k2.title = "百炼 个人"
    var k3 = Item(kind: .kept, text: "jina key jina_" + String(repeating: "ab12", count: 8), hash: "k3")
    var k4 = Item(kind: .kept, text: "Pgsql 生产 postgres://app:Pw9!secret@db.example.internal:5432/app", hash: "k4")
    let pool = [k1, k2, k3, k4, a]
    let ms = EnvMatcher.match(names: ["DASHSCOPE_API_KEY", "JINA_API_KEY", "DATABASE_URL", "STRIPE_SECRET_KEY"], items: pool, folders: [], bindings: [:])
    check(ms[0].candidates.count == 2 && ms[0].best == nil, "百炼有两个候选，不自动选")
    check(ms[1].best?.value.hasPrefix("jina_") == true, "JINA 自动匹配")
    check(ms[2].best?.value.hasPrefix("postgres://") == true, "DATABASE_URL 匹配到连接串")
    check(ms[3].candidates.isEmpty, "没有的就是没有")
    let bound = EnvMatcher.match(names: ["DASHSCOPE_API_KEY"], items: pool, folders: [], bindings: ["DASHSCOPE_API_KEY": k2.id])
    check(bound[0].best?.itemId == k2.id, "记住上次选的")
    _ = (k1, k2, k3, k4)
    let merged = EnvMatcher.mergeEnv(existing: "A=1\nB=old\n", values: [("B", "new"), ("C", "has space")])
    check(merged == "A=1\nB=new\nC=\"has space\"\n", ".env 合并：\(merged)")

    // SideNotes 导入（用一份仿造的库）
    let sn = tmp.appendingPathComponent("SideNotes.sqlite")
    var sdb: OpaquePointer?
    sqlite3_open(sn.path, &sdb)
    sqlite3_exec(sdb, """
        CREATE TABLE ZFOLDER(Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZINDEX INTEGER, ZISHIDDENDELETED INTEGER);
        CREATE TABLE ZNOTE(Z_PK INTEGER PRIMARY KEY, ZTEXT TEXT, ZFOLDER INTEGER, ZDATE REAL, ZID TEXT, ZINDEX INTEGER, ZISHIDDENDELETED INTEGER);
        INSERT INTO ZFOLDER VALUES(1,'服务器',0,0),(2,'Showcase',1,0),(3,'已删',2,1);
        INSERT INTO ZNOTE VALUES(1,'测试机 10.0.0.8 root Abc12345!',1,700000000,'a',0,0),(2,'示例笔记',2,700000000,'b',0,0),
          (3,'上线清单\n- 备份\n- 发布',1,700000001,'c',1,0),(4,'删掉的',1,700000002,'d',2,1);
        """, nil, nil, nil)
    sqlite3_close(sdb)
    let r = SideNotesImporter.importInto(again, from: sn)
    check(r.notes == 2 && r.folders == 1 && r.withSecrets == 1, "导入 2 条、1 个文件夹、1 条含密钥（实际 \(r)）")
    check(SideNotesImporter.importInto(again, from: sn).notes == 0, "重复导入不会多出一份")
} catch {
    failed += 1; print("✗ 存储测试出错：\(error)")
}

// Agent 会话解析
func writeLines(_ name: String, _ objs: [[String: Any]]) -> URL {
    let u = tmp.appendingPathComponent(name)
    let s = objs.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n"
    try! s.write(to: u, atomically: true, encoding: .utf8)
    return u
}
let now = Date()
let c1 = writeLines("c1.jsonl", [
    ["type": "user", "cwd": "/Users/x/proj/weft", "message": ["role": "user", "content": "修一下登录页"]],
    ["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "name": "Bash", "input": ["command": "npm test"]]]]],
])
let s1 = AgentScanner.parseClaude(c1, mtime: now, now: now)
check(s1?.state == .running && s1?.detail == "Bash：npm test" && s1?.project == "weft" && s1?.title == "修一下登录页", "Claude 在跑：\(String(describing: s1))")
check(AgentScanner.parseClaude(c1, mtime: now.addingTimeInterval(-60), now: now)?.state == .maybeWaiting, "卡了一分钟：可能在等你")
let c2 = writeLines("c2.jsonl", [
    ["type": "user", "cwd": "/p/site", "message": ["role": "user", "content": "发布"]],
    ["type": "assistant", "message": ["role": "assistant", "stop_reason": "tool_use", "content": [["type": "tool_use", "name": "Bash", "input": ["command": "make"]]]]],
    ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]],
    ["type": "assistant", "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "已发布到 https://a.example.com\n```bash\nmake rollback\n```"]]]],
])
let s2 = AgentScanner.parseClaude(c2, mtime: now, now: now)
check(s2?.state == .done && s2?.lastMessage.contains("已发布") == true, "Claude 完成")
let outs = AgentScanner.outputs(from: s2?.lastMessage ?? "")
check(outs.count == 2 && outs[0].text == "make rollback" && outs[0].type == .command && outs[1].text == "https://a.example.com", "拆出产出：\(outs)")
let x1 = writeLines("x1.jsonl", [
    ["type": "session_meta", "payload": ["session_id": "abc", "cwd": "/p/api", "originator": "Codex Desktop"]],
    ["type": "event_msg", "payload": ["type": "task_started"]],
    ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "跑迁移"]]]],
    ["type": "response_item", "payload": ["type": "function_call", "name": "shell", "arguments": "{\"command\":\"make migrate\"}"]],
])
let sx = AgentScanner.parseCodex(x1, mtime: now, now: now)
check(sx?.state == .running && sx?.detail == "shell：make migrate" && sx?.title == "跑迁移" && sx?.hostBundle == "com.openai.codex", "Codex 在跑：\(String(describing: sx))")
let x2 = writeLines("x2.jsonl", [
    ["type": "session_meta", "payload": ["session_id": "abd", "cwd": "/p/api"]],
    ["type": "event_msg", "payload": ["type": "task_started"]],
    ["type": "event_msg", "payload": ["type": "task_complete", "last_agent_message": "迁移完成"]],
])
check(AgentScanner.parseCodex(x2, mtime: now, now: now)?.lastMessage == "迁移完成", "Codex 完成")

// 目标窗口类别
check(TargetKind.of(bundle: "com.tencent.xinWeChat") == .chat && TargetKind.of(bundle: "org.tabby") == .terminal
      && TargetKind.of(bundle: "com.microsoft.Outlook") == .rich && TargetKind.of(bundle: "com.openai.codex") == .ai, "目标窗口类别")

// 进程间通信
let server = IPCServer { req, reply in reply(["echo": req["cmd"] ?? "", "ok": true]) }
check(server.start(), "通信服务启动")
var ipcAnswer: [String: Any]?
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async { ipcAnswer = IPC.request(["cmd": "ping"], timeout: 3); done.signal() }
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check(ipcAnswer?["echo"] as? String == "ping", "通信往返")
server.stop()

try? FileManager.default.removeItem(at: tmp)
// 用真实的 SideNotes 库试跑导入，只输出统计数字（不输出任何内容）。REACH_IMPORT_STATS=1 时才跑，数据进临时目录。
if ProcessInfo.processInfo.environment["REACH_IMPORT_STATS"] == "1", let url = SideNotesImporter.available {
    let st = try! Store(vault: try! Vault.open())
    let r = SideNotesImporter.importInto(st, from: url)
    print("导入：\(r.notes) 条，\(r.folders) 个文件夹，含密钥 \(r.withSecrets)，跳过 \(r.skipped)")
    var types: [String: Int] = [:], labels: [String: Int] = [:], shapes: [String: Int] = [:]
    var tpl = 0, titleMasked = 0, cjk = 0, nsec = 0
    for it in st.kept {
        types[it.ctype.label, default: 0] += 1
        if !it.sensitive, !Template.slots(in: it.text).isEmpty { tpl += 1 }
        if SecretDetector.mask(it.displayTitle, loose: true) != it.displayTitle { titleMasked += 1 }
        for s in SecretDetector.find(in: it.text, loose: true) {
            nsec += 1
            labels[s.label, default: 0] += 1
            if s.value.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { cjk += 1 }
            let n = s.value.count
            shapes[n < 8 ? "<8" : n < 12 ? "8-11" : n < 20 ? "12-19" : n < 40 ? "20-39" : "40+", default: 0] += 1
        }
    }
    print("类型：\(types.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))")
    print("认出的密钥 \(nsec) 个：\(labels.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))")
    print("长度分布：\(shapes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "，"))；含中文的 \(cjk)")
    print("标题被打码的 \(titleMasked) 条；会被当成模板的 \(tpl) 条")
    let again = SideNotesImporter.importInto(st, from: url)
    print("再导一次新增：\(again.notes)")
}
print(failed == 0 ? "✓ 全部通过（\(passed) 项）" : "✗ \(failed) 项失败，\(passed) 项通过")
exit(failed == 0 ? 0 : 1)
