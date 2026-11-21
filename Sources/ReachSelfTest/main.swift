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

// 一条里好几个密钥：从上下文取名字分清
let k1 = "sk-" + String(repeating: "Qw3rT7", count: 6), k2 = "sk-" + String(repeating: "Zx9cV2", count: 6), k3 = "sk-" + String(repeating: "Mn5bH8", count: 6)
func secretNames(_ t: String) -> [String] { FieldParser.parse(t).filter { $0.kind == .secret }.map { $0.name ?? "-" } }
check(secretNames("OpenAI: \(k1)\nDEEPSEEK_API_KEY=\(k2)\n- 公司 Claude 的 key \(k3)") == ["OpenAI", "DEEPSEEK", "公司 Claude"], "同一行前面的字当名字（实际 \(secretNames("OpenAI: \(k1)\nDEEPSEEK_API_KEY=\(k2)\n- 公司 Claude 的 key \(k3)"))）")
check(secretNames("## 生产\n\(k1)\n\n## 测试\n\(k2)") == ["生产", "测试"], "只有密钥的行用上面的小标题")
check(secretNames("后台 https://a.example.com\n账号 ops@example.com\n密码 Passw0rd!x\nkey: \(k1)") == ["ops@example.com", "-"], "密码用上面的账号当名字，网址行不用（实际 \(secretNames("后台 https://a.example.com\n账号 ops@example.com\n密码 Passw0rd!x\nkey: \(k1)"))）")
check(secretNames("## 生产\nroot@10.0.3.21\n密码 Prod#2026x\n\n## 测试\nroot@10.0.3.40\n密码 Test#2026y") == ["生产", "测试"], "同一段里的小标题优先于主机行")
check(secretNames("\(k1)\n\(k2)") == ["第1个", "第2个"], "实在没名字的按第几个分")
check(secretNames("export MONKEY_TOKEN=\(k1)\nexport DONKEY_TOKEN=\(k2)") == ["MONKEY", "DONKEY"], "不会把 Monkey 里的 key 删掉")
check(secretNames("AK \(k1) SK \(k2)") == ["AK", "SK"], "同一行两个密钥各取各的")
check(FieldParser.parse("key: \(k1)").first { $0.kind == .secret }?.name == nil, "只有一个密钥不起名")
check(SecretDetector.maskHint("Passw0rd!x") == "•••••• 10 位" && SecretDetector.maskHint(k1).hasSuffix(String(k1.suffix(4))), "短密码只说位数，长 Key 露头尾")

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

let now = Date()

// 截图翻译、看懂
check(ShotAI.translateTarget(["Settings", "Sign in to continue"]) == "简体中文" && ShotAI.translateTarget(["设置", "登录后继续"]) == "English", "翻译方向")
check(ShotAI.worthTranslating("Sign in", to: "简体中文") && !ShotAI.worthTranslating("12:30", to: "简体中文") && !ShotAI.worthTranslating("登录", to: "简体中文"), "哪些行要翻")
check(ShotAI.translateTarget(["設定を保存しました", "ログインしてください", "東京都"]) == "简体中文", "日文译成中文")
check(ShotAI.translateTarget(["ファイル", "ログイン"]) == "简体中文" && ShotAI.translateTarget(["설정이 저장되었습니다"]) == "简体中文", "纯假名、韩文也译成中文")
check(ShotAI.worthTranslating("ログインしてください", to: "简体中文") && ShotAI.worthTranslating("設定を保存しました", to: "简体中文"), "日文行要翻（含汉字的也翻）")
check(ShotAI.translateTarget(["设置已保存", "请先登录 GitHub 再继续"]) == "English", "中文还是译成英文")
check(ShotAI.parseLines("```json\n[\"设置\", \"登录\"]\n```", count: 2) == ["设置", "登录"], "解析译文（带代码块记号）")
check(ShotAI.parseLines("[\"设置\"]", count: 2) == nil, "行数对不上就不用")
check(ShotAI.segments("原因是端口被占。\n```bash\nlsof -i :3000\n```\n然后重启。") == [.text("原因是端口被占。"), .code("lsof -i :3000"), .text("然后重启。")], "回答拆出代码块")
check(!ShotAI.explainUser(lines: ["key: sk-proj-abcdefghijklmnopqrstuvwxyz123456"], app: "终端").contains("abcdefghijklmnop"), "发给模型前抹掉密钥")
let mp = Magpie.parseModels(Data(#"{"data":[{"id":"zhipu/glm-5","magpie_label":"GLM-5 · Zhipu","modalities":{"input":["text"]}},{"id":"codex/gpt","display_name":"GPT","modalities":{"input":["text","image"]}}]}"#.utf8))
check(mp.count == 2 && mp[0].label == "GLM-5 · Zhipu" && !mp[0].vision && mp[1].vision && mp[1].label == "GPT", "读 Magpie 模型列表：\(mp)")
let mhome = tmp.appendingPathComponent("mhome")
try? FileManager.default.createDirectory(at: mhome.appendingPathComponent(".config/magpie"), withIntermediateDirectories: true)
try? #"{"addr":"127.0.0.1:4555"}"#.write(to: mhome.appendingPathComponent(".config/magpie/gateway.json"), atomically: true, encoding: .utf8)
check(Magpie.baseURL(home: mhome) == "http://127.0.0.1:4555/v1" && Magpie.baseURL(home: tmp) == "http://127.0.0.1:3425/v1", "Magpie 地址")
let oldAI = try! JSONDecoder().decode(AISettings.self, from: Data(#"{"baseURL":"x","model":"m","apiKey":"","enabled":true}"#.utf8))
check(oldAI.isReady && !oldAI.vision, "旧版 AI 设置读得进来")

// AI 返回
check((try? AIError.answer(from: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"可以","reasoning_content":"想一想"}}]}"#.utf8))) == "可以", "思考型模型的回答")
check((try? AIError.answer(from: Data(#"{"choices":[{"message":{"content":"<think>嗯</think>\n可以"}}]}"#.utf8))) == "可以", "去掉 think 段")
do { _ = try AIError.answer(from: Data(#"{"choices":[{"finish_reason":"length","message":{"content":null,"reasoning_content":"…"}}]}"#.utf8)); check(false, "字数用完应报错") }
catch { check("\(error)".contains("字数用完"), "思考把字数用完：\(error)") }
let e403 = AIError.http(403, AIError.message(from: Data(#"{"error":{"message":"原 Key: 403 Forbidden: This account only allows Codex official clients"}}"#.utf8)))
check(e403.description.contains("Codex"), "403 说清原因：\(e403)")
check(AIError.http(500, AIError.message(from: Data(#"{"error":{"message":"upstream down"}}"#.utf8))).description == "500：upstream down", "错误信息原样给出")

// 检查更新
check(UpdateCheck.isNewer("v0.5.10", than: "0.5.9") && !UpdateCheck.isNewer("v0.5.1", than: "0.5.1") && !UpdateCheck.isNewer("0.4.9", than: "0.5") && UpdateCheck.isNewer("1.0", than: "0.9.9"), "版本号比较")
check(UpdateCheck.sha(for: "Reach-0.5.1.zip", in: "ABC123  Reach-0.5.1.zip\ndef  Reach-0.5.1.dmg\n") == "abc123" && UpdateCheck.sha(for: "x.zip", in: "a  y.zip") == nil, "找校验和")

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
// 截图认字：打码位置和可拿走的东西
do {
    let key = "sk-proj-" + String(repeating: "aB3dE6fG9h", count: 4)
    let line = "OPENAI_API_KEY=" + key
    let rs = ShotText.secretRanges(in: line)
    check(rs.count == 1 && (line as NSString).substring(with: rs[0]) == key, "截图里的 Key 只遮值本身")
    check(ShotText.secretRanges(in: "修改密码功能已上线").isEmpty, "说到密码的句子不遮")
    let conn = "postgres://app:Xk29fLq7pW@db.internal:5432/orders"
    check(!ShotText.secretRanges(in: conn).isEmpty, "连接串里的密码要遮")
    let f = ShotText.findings(lines: ["订单管理", "TypeError: Cannot read properties of undefined (reading 'map')", "at OrderList (OrderList.tsx:42:18)",
                                      "$ npm run dev -- --port 3001", "https://github.com/vercel/next.js/discussions/48110", line])
    let labels = f.map(\.label)
    check(labels.contains("报错") && labels.contains("网址") && labels.contains("全部文字"), "截图里认出报错、网址（实际 \(labels)）")
    check(f.first { $0.label == "报错" }?.value.hasPrefix("TypeError") == true, "报错从错误那行开始")
    check(!(f.first { $0.label == "全部文字" }?.value.contains(key) ?? true), "全部文字里的 Key 打码")
    check(!f.contains { $0.label != "全部文字" && $0.value.contains(key) }, "带 Key 的不给一键复制")
    check(!ShotText.findings(lines: ["数据库 " + conn]).contains { $0.label == "网址" }, "带密码的连接串不当网址给")
    check(ShotText.findings(lines: []).isEmpty, "没认出字就什么都不给")
    check(ShotText.findings(lines: ["~/code/shop-web ❯ npm run dev -- --port 3001"]).first { $0.label == "命令" }?.value == "npm run dev -- --port 3001", "提示符后面的命令认得出")
    check(ShotText.findings(lines: ["~/code/shop-web 》npm run dev -- --port 3001"]).contains { $0.label == "命令" }, "认字把提示符认成》也行")
}

// 链接分流
do {
    let u = { (s: String) in URL(string: s)! }
    check(LinkLogic.unwrap(u("https://slack-redirect.slack.com/?url=https%3A%2F%2Fx.com%2Fa%2Fstatus%2F1")).absoluteString == "https://x.com/a/status/1", "剥掉 Slack 跳转壳")
    check(LinkLogic.unwrap(u("https://www.google.com/url?q=https://claude.ai/chat/1&sa=D")).host == "claude.ai", "剥掉 Google 跳转壳")
    check(LinkLogic.unwrap(u("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fdocs.google.com%2Fd%2F1&data=x")).host == "docs.google.com", "剥掉 Outlook 安全链接")
    check(LinkLogic.unwrap(u("https://link.zhihu.com/?target=https%3A%2F%2Fgithub.com%2Fa")).host == "github.com", "剥掉知乎跳转")
    check(LinkLogic.unwrap(u("https://www.google.com/search?q=https://x.com")).host == "www.google.com", "Google 搜索页不剥")
    check(LinkLogic.unwrap(u("https://x.com/home?u=https://evil.com")).host == "x.com", "普通网站带 url 参数不剥")
    check(LinkLogic.siteCovers("x.com", u("https://mobile.x.com/a")) && !LinkLogic.siteCovers("x.com", u("https://notx.com/")), "子域名算，同后缀的别家不算")
    check(LinkLogic.siteCovers("github.com/corp", u("https://github.com/Corp/repo")) && !LinkLogic.siteCovers("github.com/corp", u("https://github.com/corporate")), "路径前缀按整段匹配")
    check(LinkLogic.suggestedSite(u("https://github.com/anthropics/x/pull/1")) == "github.com/anthropics" && LinkLogic.suggestedSite(u("https://www.x.com/a")) == "x.com", "建议的规则网站")
    let work = LinkTarget(browser: "com.google.Chrome", profile: "Profile 1"), me = LinkTarget(browser: "com.google.Chrome", profile: "Default"),
        alt = LinkTarget(browser: "com.brave.Browser", group: "小号")
    let rules = [LinkRule(source: "com.tinyspeck.slackmacgap", target: work),
                 LinkRule(site: "docs.google.com", target: me),
                 LinkRule(site: "docs.google.com", source: "com.tinyspeck.slackmacgap", target: work),
                 LinkRule(site: "github.com", target: me), LinkRule(site: "github.com/corp", target: work),
                 LinkRule(site: "x.com", target: alt)]
    check(LinkLogic.match(rules, url: u("https://docs.google.com/d/1"), source: "com.tinyspeck.slackmacgap")?.target == work, "网站+来源最优先")
    check(LinkLogic.match(rules, url: u("https://docs.google.com/d/1"), source: "com.tencent.xinWeChat")?.target == me, "其次网站")
    check(LinkLogic.match(rules, url: u("https://example.com/"), source: "com.tinyspeck.slackmacgap")?.target == work, "再次来源")
    check(LinkLogic.match(rules, url: u("https://x.com/a"), source: "com.tinyspeck.slackmacgap")?.target == alt, "网站规则压过来源规则")
    check(LinkLogic.match(rules, url: u("https://github.com/corp/a"), source: nil)?.target == work && LinkLogic.match(rules, url: u("https://github.com/me/a"), source: nil)?.target == me, "路径越长越优先")
    check(LinkLogic.match(rules, url: u("https://example.com/"), source: nil) == nil, "没有规则就不命中")
    var ls = LinkSettings()
    check(LinkLogic.learn(&ls, site: "x.com", target: alt) == nil, "选一次不记规则")
    check(LinkLogic.learn(&ls, site: "x.com", target: me) == nil, "换了去处重新数")
    check(LinkLogic.learn(&ls, site: "x.com", target: me)?.target == me && ls.rules.count == 1 && ls.streaks["x.com"] == nil, "连续两次同一去处记成规则")
    LinkLogic.upsert(&ls.rules, LinkRule(site: "x.com", target: alt))
    check(ls.rules.count == 1 && ls.rules[0].target == alt, "同网站的规则替换不重复")
    // 保守推测
    var v = SiteVisits()
    for i in 0..<19 { v.add(me.profileKey, at: Double(i)) }
    v.add(work.profileKey, at: 1.5)
    check(LinkLogic.guess(url: u("https://claude.ai/"), visits: v, domains: [:]).sure == me.profileKey, "一个账号占 95% 且最近 3 次都在它：直接开")
    var v2 = v; v2.add(work.profileKey, at: 100)
    check(LinkLogic.guess(url: u("https://claude.ai/"), visits: v2, domains: [:]).sure == nil, "最近一次在别的账号：不直接开")
    check(LinkLogic.guess(url: u("https://claude.ai/"), visits: v2, domains: [:]).ranked.first == me.profileKey, "但排第一")
    var v3 = SiteVisits(); for i in 0..<6 { v3.add(me.profileKey, at: Double(i)) }
    check(LinkLogic.guess(url: u("https://claude.ai/"), visits: v3, domains: [:]).sure == nil, "次数太少不直接开")
    let d = [work.profileKey: "corp.com", me.profileKey: ""]
    check(LinkLogic.guess(url: u("https://wiki.corp.com/a"), visits: v, domains: d).sure == work.profileKey, "企业域名对上直接开")
    check(LinkLogic.guess(url: u("https://wiki.corp.com/a"), visits: nil, domains: [work.profileKey: "corp.com", "b": "corp.com"]).sure == nil, "两个账号同一个企业域名：要问")
    check(LinkLogic.group(of: "公司 客户A") == "公司" && LinkLogic.group(of: "公司-周报") == "公司" && LinkLogic.group(of: "个人") == "个人", "窗口组名取第一个词")
    let scrubbed = LinkLogic.scrub(u("https://u:pw@app.example.com/cb?state=ok&access_token=abc123xyz&X-Amz-Signature=deadbeef#id_token=zzz"))
    check(!scrubbed.contains("abc123xyz") && !scrubbed.contains("deadbeef") && !scrubbed.contains("zzz") && !scrubbed.contains("pw@") && scrubbed.contains("state=ok"), "点过的链接存之前擦掉 token、签名、密码（\(scrubbed)）")
    check(LinkLogic.scrub(u("https://x.com/a/status/1?s=20")) == "https://x.com/a/status/1?s=20", "普通链接原样")
    check(LinkTarget(key: alt.key) == alt && LinkTarget(key: work.key) == work && LinkTarget(key: "") == nil, "去处 key 能还原")
    var st = Settings(); st.links.enabled = true; st.links.rules = rules
    let back = try! JSONDecoder().decode(Settings.self, from: try! JSONEncoder().encode(st))
    check(back.links == st.links, "分流设置能存能读")
    check((try? JSONDecoder().decode(Settings.self, from: Data("{\"links\":{\"unknown\":\"weird\"}}".utf8)))?.links.unknown == .guess, "坏的设置退回默认")
}

// 点过的链接：30 天后清掉，不进复制历史
do {
    let st = try! Store(vault: try! Vault.open())
    var v = Item(kind: .visit, ctype: .link, text: "https://x.com/old"); v.expiresAt = Date().addingTimeInterval(-10); v.useCount = 9; v.lastUsedAt = Date()
    var v2 = Item(kind: .visit, ctype: .link, text: "https://x.com/new"); v2.expiresAt = Date().addingTimeInterval(86400); v2.openedIn = "com.google.Chrome|Default|"
    st.save(v); st.save(v2)
    _ = st.purgeExpired()
    check(st.items[v.id] == nil && st.items[v2.id] != nil, "过期的点过的链接被清掉（用过很多次也清）")
    check(!st.clips.contains { $0.id == v2.id } && st.visits.first?.openedIn == "com.google.Chrome|Default|", "不混进复制历史，去处存下来了")
}

// 用真实的 SideNotes 库试跑导入，只输出统计数字（不输出任何内容）。REACH_IMPORT_STATS=1 时才跑，数据进临时目录。
check(ShotAI.segments("译文：\n> 第一行\n>\n> 第二行") == [.text("译文：\n第一行\n\n第二行")], "引用记号去掉")

// 就地候选：排序
do {
    let now = Date()
    func clip(_ t: String, ago: TimeInterval, app: String? = nil, ctype: ContentType? = nil) -> Item {
        var it = Item(kind: .clip, text: t, sourceApp: app, createdAt: now.addingTimeInterval(-ago), hash: "c-" + t)
        it.ctype = ctype ?? Classifier.classify(t); return it
    }
    let fresh = clip("刚复制的一段话", ago: 30, app: "Safari")
    let old = clip("昨天的一段话", ago: 30 * 3600)
    let cmd = clip("git push origin main", ago: 4000, ctype: .command)
    let key = clip(fake, ago: 600, ctype: .secret)
    var gh = Item(kind: .kept, text: "GitHub\n账号 me@example.com\n密码 Gh!pass9word", hash: "k-gh"); gh.title = "GitHub"; gh.sensitive = true; gh.ctype = .credential
    var aws = Item(kind: .kept, text: "AWS 控制台\n账号 ops@corp.example\n密码 Aws#9secretpw", hash: "k-aws"); aws.title = "AWS"; aws.sensitive = true; aws.ctype = .credential
    var note2 = Item(kind: .kept, text: "一段很少用的笔记", hash: "k-note")
    note2.useCount = 0
    let pool2 = [fresh, old, cmd, key, gh, aws, note2]

    let chat = InlineRank.rank(pool2, folders: [], ctx: InlineContext(field: .chat, target: .chat, now: now))
    check(chat.first?.itemId == fresh.id, "聊天窗口：刚复制的排第一")
    check(!chat.contains { $0.itemId == key.id || $0.itemId == gh.id || $0.itemId == aws.id }, "聊天窗口不出现密钥")
    check(!chat.contains { $0.itemId == note2.id }, "抽屉里不相关的不挤进来")

    let pw = InlineRank.rank(pool2, folders: [], ctx: InlineContext(field: .password, target: .browser, hints: ["Sign in to GitHub · GitHub"], now: now))
    check(pw.first?.itemId == gh.id && pw.first?.value == "Gh!pass9word", "密码框：和网站对得上的密码排第一，只贴密码（实际 \(pw.map(\.title))）")
    check(pw.allSatisfy { $0.secret } && !pw.contains { $0.itemId == fresh.id }, "密码框只给密码")
    check(pw.allSatisfy { !$0.title.contains("Gh!pass9word") && !$0.title.contains("Aws#9secretpw") }, "候选条上看不到密码原文")

    let acct = InlineRank.rank(pool2, folders: [], ctx: InlineContext(field: .account, target: .browser, hints: ["AWS Management Console"], now: now))
    check(acct.first?.itemId == aws.id && acct.first?.value == "ops@corp.example", "账号框：贴账号（实际 \(acct.map { $0.value ?? "-" })）")

    let term = InlineRank.rank(pool2, folders: [], ctx: InlineContext(field: .terminal, target: .terminal, now: now))
    check(term.first?.itemId == fresh.id && term.dropFirst().first?.itemId == cmd.id, "终端：刚复制的之后是命令")
    check(term.first { $0.itemId == key.id }.map { !$0.title.contains(fake) } ?? true, "终端里出现的密钥也打码")

    var used = clip("在 Tabby 里常贴的", ago: 3 * 86400); used.useByApp["org.tabby"] = 4
    let other = InlineRank.rank([old, used], folders: [], ctx: InlineContext(field: .other, target: .terminal, bundle: "org.tabby", now: now))
    check(other.first?.itemId == used.id, "在这个 App 里常贴的排前")
    let dup = InlineRank.rank([fresh, fresh], folders: [], ctx: InlineContext(field: .other, target: .other, now: now))
    check(dup.count == 1, "同样的内容只出一次")

    check(InlineContext.field(role: "AXTextField", subrole: "AXSecureTextField", texts: [], target: .browser) == .password, "认出密码框")
    check(InlineContext.field(role: "AXTextField", subrole: nil, texts: ["Address and search bar"], target: .browser) == .url, "认出地址栏")
    check(InlineContext.field(role: "AXTextField", subrole: nil, texts: ["请输入邮箱"], target: .other) == .account, "认出账号框")
    check(InlineContext.field(role: "AXTextArea", subrole: nil, texts: [], target: .chat) == .chat, "聊天输入框")
}

// 就地候选：长按 ⌘V 的按键判定
do {
    var m = HoldPaste()
    let down = HoldPaste.Key.vDown(repeat: false, shift: false, cmd: true, otherMods: false)
    var r = m.handle(down)
    check(r.swallow && r.effects == [.startTimer], "按下 ⌘V 先吞掉、开始计时")
    r = m.handle(.vUp)
    check(r.swallow && r.effects == [.cancelTimer, .postPaste] && m.state == .idle, "短按：照常粘贴")
    _ = m.handle(down); r = m.handle(.cmdUp)
    check(!r.swallow && r.effects.contains(.postPaste), "先松 ⌘ 也算短按")
    check(!m.handle(.vDown(repeat: false, shift: false, cmd: true, otherMods: true)).swallow, "⌥⌘V、⌃⌘V 不管")
    check(!m.handle(.vDown(repeat: false, shift: false, cmd: false, otherMods: false)).swallow, "单按 V 不管")
    check(!m.handle(.vDown(repeat: false, shift: true, cmd: true, otherMods: false)).swallow && m.state == .idle, "⇧⌘V（打开侧栏）原样放过")
    _ = m.handle(down)
    check(m.handle(.vDown(repeat: true, shift: false, cmd: true, otherMods: false)).swallow, "按住时的连发吞掉")
    r = m.handle(.timer)
    check(r.effects == [.resolve] && m.state == .resolving, "按够时间：去算候选")
    r = m.handle(.ready(0))
    check(r.effects == [.postPaste] && m.state == .idle, "没有候选：照常粘贴")
    _ = m.handle(down); _ = m.handle(.timer); r = m.handle(.ready(3))
    check(r.effects == [.show] && m.state == .showing, "有候选：出候选条")
    check(m.handle(.vUp).swallow, "出候选条后松开 V 不贴")
    _ = m.handle(down); _ = m.handle(down)
    check(m.index == 2, "再按 V 往后跳")
    _ = m.handle(down)
    check(m.index == 0, "跳到头回到第一个")
    _ = m.handle(.vDown(repeat: false, shift: true, cmd: true, otherMods: false))
    check(m.index == 2, "⇧V 往回")
    check(m.handle(.vDown(repeat: true, shift: false, cmd: true, otherMods: false)).effects.isEmpty && m.index == 2, "连发不跳")
    r = m.handle(.cmdUp)
    check(r.effects == [.choose(2)] && !r.swallow && m.state == .idle, "松开 ⌘ 贴高亮那条")
    _ = m.handle(down); _ = m.handle(.timer); _ = m.handle(.ready(3))
    check(m.handle(.other(code: 53)).effects == [.cancel], "Esc 取消")
    _ = m.handle(down); _ = m.handle(.timer); _ = m.handle(.ready(3))
    check(m.handle(.other(code: 19)).effects == [.choose(1)], "数字键直接选")
    _ = m.handle(down); _ = m.handle(.timer); _ = m.handle(.ready(3))
    check(m.handle(.other(code: 125)).effects == [.expand], "↓ 展开")
    _ = m.handle(down); _ = m.handle(.timer)
    r = m.handle(.cmdUp)
    check(r.effects == [.postPaste] && m.state == .idle, "候选还没算好就松手：照常粘贴")
    check(m.handle(.ready(3)).effects.isEmpty && m.state == .idle, "晚到的候选不出来")
}

// 保留时间：贴过的续期，「不限」
do {
    let vault = try Vault.open()
    let st = try Store(vault: vault)
    st.settings.retentionDays = 30
    var c = Item(kind: .clip, text: "续期测试", hash: "renew")
    c.expiresAt = Date().addingTimeInterval(86400)
    st.save(c)
    st.recordUse(c.id, app: nil)
    check((st.items[c.id]?.expiresAt ?? .distantPast) > Date().addingTimeInterval(29 * 86400), "贴过一次重新算保留时间")
    var sk = Item(kind: .clip, ctype: .secret, text: fake, hash: "renew-secret")
    sk.expiresAt = Date().addingTimeInterval(600); sk.sensitive = true
    st.save(sk)
    st.recordUse(sk.id, app: nil)
    check((st.items[sk.id]?.expiresAt ?? .distantFuture) < Date().addingTimeInterval(3600), "密钥贴过也不续")
    var forever = Item(kind: .clip, text: "不限时留下的", createdAt: Date().addingTimeInterval(-40 * 86400), hash: "forever")
    forever.expiresAt = nil
    st.save(forever)
    st.settings.retentionDays = 0
    _ = st.purgeExpired()
    check(st.items[forever.id] != nil, "不限：不清")
    st.settings.retentionDays = 30
    _ = st.purgeExpired()
    check(st.items[forever.id] == nil, "改回 30 天：按复制那天算，过期的清掉")
    check(Settings().maxClips == 3000, "默认最多 3000 条")
}

// 从 Paste 搬家：Core Data 字段的几种存法
do {
    let items: [[String: Any]] = [["types": ["public.utf8-plain-text", "public.html"],
                                   "dataByType": ["public.utf8-plain-text": Data("从 Paste 来的".utf8), "public.html": Data("<b>x</b>".utf8)]]]
    let plist = try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
    let ext = FileManager.default.temporaryDirectory
    check(PasteImporter.decode(Data([1]) + plist, external: ext)?.count == 1, "内嵌的 bplist")
    let lz = try (plist as NSData).compressed(using: .lzfse) as Data
    check(PasteImporter.decode(Data([1]) + lz, external: ext)?.count == 1, "LZFSE 压过的")
    let json = try JSONSerialization.data(withJSONObject: [["types": ["public.utf8-plain-text"], "dataByType": ["public.utf8-plain-text": Data("json 的".utf8).base64EncodedString()]]])
    let z = try (json as NSData).compressed(using: .zlib) as Data
    let dj = PasteImporter.decode(Data([1]) + z, external: ext)
    check(dj?.count == 1, "deflate 压过的 JSON")
    let uuid = UUID().uuidString
    try plist.write(to: ext.appendingPathComponent(uuid))
    check(PasteImporter.decode(Data([2]) + Data(uuid.utf8) + Data([0]), external: ext)?.count == 1, "存在外部文件里的")
    var e = PasteImporter.Entry(created: Date(), used: Date())
    PasteImporter.fill(&e, from: items)
    check(e.text == "从 Paste 来的" && e.html == "<b>x</b>", "取出文字和富文本")
    var e2 = PasteImporter.Entry(created: Date(), used: Date())
    PasteImporter.fill(&e2, from: dj ?? [])
    check(e2.text == "json 的", "JSON 里的 base64")

    let vault = try Vault.open()
    let st = try Store(vault: vault)
    st.settings.retentionDays = 30
    let before = st.items.count
    var board = PasteImporter.Entry(text: "常用回复：收到，马上处理", created: Date(), used: Date().addingTimeInterval(-86400)); board.board = "常用"
    let hist = PasteImporter.Entry(text: "一条历史", app: "Safari", created: Date(), used: Date().addingTimeInterval(-3 * 86400))
    let sec = PasteImporter.Entry(text: fake, created: Date(), used: Date())
    let res = PasteImporter.importInto(st, entries: [board, hist, sec], pngOf: { $0 })
    check(res.clips == 1 && res.kept == 1 && res.secrets == 1, "历史进最近复制、Pinboard 进抽屉、整条密钥不搬（\(res)）")
    check(st.kept.contains { k in k.text.hasPrefix("常用回复") && st.folders.first { f in f.id == k.folderId }?.name == "常用" }, "Pinboard 变成同名文件夹")
    let h = st.clips.first { $0.text == "一条历史" }
    check(h?.origin == .imported && h?.sourceApp == "Safari" && (h?.expiresAt ?? .distantPast) > Date().addingTimeInterval(29 * 86400), "搬来的历史从今天起算保留时间")
    let again = PasteImporter.importInto(st, entries: [board, hist], pngOf: { $0 })
    check(again.clips == 0 && again.kept == 0 && st.items.count == before + 2, "再搬一次不重复")
}

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
