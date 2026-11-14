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
