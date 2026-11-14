import Foundation

/// clip 复制历史，kept 抽屉，visit 从别的 App 点开、经过链接分流的链接（只进搜索，30 天后清掉）
public enum ItemKind: String, Codable { case clip, kept, visit }

public enum ContentType: String, Codable, CaseIterable {
    case text, link, command, error, code, json, table, credential, secret, image, file, email, phone, path

    public var label: String {
        switch self {
        case .text: return "文字"
        case .link: return "链接"
        case .command: return "命令"
        case .error: return "报错"
        case .code: return "代码"
        case .json: return "JSON"
        case .table: return "表格"
        case .credential: return "账号"
        case .secret: return "密钥"
        case .image: return "图片"
        case .file: return "文件"
        case .email: return "邮箱"
        case .phone: return "电话"
        case .path: return "路径"
        }
    }
}

public enum Origin: String, Codable { case copied, agent, imported, manual }

/// 侧栏里的一张卡片。复制历史（clip）和抽屉（kept）是同一种东西，区别只在会不会过期。
public struct Item: Codable, Identifiable, Equatable {
    public var id: String
    public var kind: ItemKind
    public var ctype: ContentType
    public var title: String
    public var text: String
    /// 复制时带的富文本（用于原样带格式粘贴）
    public var html: String?
    /// 加密图片文件名（images/ 下）
    public var imageFile: String?
    public var files: [String]?
    /// 截图识别出的文字
    public var ocr: String?
    public var sourceApp: String?
    public var sourceBundle: String?
    public var origin: Origin
    public var agentSession: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
    public var useCount: Int
    /// 在哪个 App 里贴过几次，用来排序
    public var useByApp: [String: Int]
    public var expiresAt: Date?
    public var groupId: String?
    public var folderId: String?
    public var sensitive: Bool
    /// 用户标记过"这不是密钥"的值
    public var notSecret: [String]
    public var hash: String
    /// 点过的链接：开到了哪里（LinkTarget.key）
    public var openedIn: String?

    public init(id: String = UUID().uuidString, kind: ItemKind, ctype: ContentType = .text, title: String = "", text: String,
                html: String? = nil, imageFile: String? = nil, files: [String]? = nil, sourceApp: String? = nil,
                sourceBundle: String? = nil, origin: Origin = .copied, agentSession: String? = nil,
                createdAt: Date = Date(), groupId: String? = nil, folderId: String? = nil, sensitive: Bool = false, hash: String = "") {
        self.id = id; self.kind = kind; self.ctype = ctype; self.title = title; self.text = text
        self.html = html; self.imageFile = imageFile; self.files = files; self.ocr = nil
        self.sourceApp = sourceApp; self.sourceBundle = sourceBundle; self.origin = origin; self.agentSession = agentSession
        self.createdAt = createdAt; self.updatedAt = createdAt; self.lastUsedAt = nil; self.useCount = 0; self.useByApp = [:]
        self.expiresAt = nil; self.groupId = groupId; self.folderId = folderId; self.sensitive = sensitive
        self.notSecret = []; self.hash = hash
    }

    /// 显示用标题：有标题用标题，否则取正文第一行
    public var displayTitle: String {
        if !title.isEmpty { return title }
        if ctype == .image { return ocr.flatMap { Text.firstLine($0, max: 40) } ?? "图片" }
        if ctype == .file { return (files ?? []).map { ($0 as NSString).lastPathComponent }.joined(separator: "、") }
        return Text.firstLine(Text.stripMarks(text), max: 60) ?? "（空）"
    }

    /// 参与搜索的全部文字
    public var searchable: String {
        [title, text, ocr ?? "", (files ?? []).joined(separator: " "), sourceApp ?? ""].joined(separator: "\n")
    }
}

public struct Folder: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var order: Int
    public init(id: String = UUID().uuidString, name: String, order: Int = 0) {
        self.id = id; self.name = name; self.order = order
    }
}

public struct AISettings: Codable, Equatable {
    public var baseURL: String = ""
    public var model: String = ""
    public var apiKey: String = ""
    public var enabled: Bool = false
    /// 模型能看图：截图「看懂」时把（打过码的）图也发过去
    public var vision: Bool = false
    public init() {}
    public var isReady: Bool { enabled && !baseURL.isEmpty && !model.isEmpty }

    enum CodingKeys: String, CodingKey { case baseURL, model, apiKey, enabled, vision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        vision = try c.decodeIfPresent(Bool.self, forKey: .vision) ?? false
    }
}

/// 一组快捷键：Carbon 键码 + 修饰键（cmdKey 256、shiftKey 512、optionKey 2048、controlKey 4096），label 是显示用的「⇧⌘V」
public struct KeyCombo: Codable, Equatable {
    public var code: Int
    public var mods: Int
    public var label: String
    public init(code: Int, mods: Int, label: String) { self.code = code; self.mods = mods; self.label = label }
    public static let defaultPanel = KeyCombo(code: 9, mods: 256 | 512, label: "⇧⌘V")
    public static let defaultShot = KeyCombo(code: 0, mods: 4096 | 2048, label: "⌃⌥A")
    /// 备用的打开侧栏快捷键（⇧⌘V 常被 Paste 占着）
    public static let backupPanel = KeyCombo(code: 9, mods: 4096 | 2048, label: "⌃⌥V")
}

public struct Settings: Codable, Equatable {
    public var paused = false
    /// 普通 ⌘V 时也按目标窗口调整格式
    public var ambientFormat = false
    public var retentionDays = 30
    public var secretClipMinutes = 60
    public var hotEdge = true
    public var edgeLeft = false
    /// 屏幕边上露一个小把手：鼠标滑上去或点一下打开侧栏
    public var edgeHandle = true
    /// 把手的高度（0 = 最上，1 = 最下）
    public var handleY = 0.5
    /// 开机自动打开
    public var launchAtLogin = true
    /// 打开侧栏的快捷键（设置里可以录新的）
    public var panelKey = KeyCombo.defaultPanel
    /// 截图快捷键开关和按键
    public var shotHotkey = true
    public var shotKey = KeyCombo.defaultShot
    /// 截图里认出的密钥自动打码
    public var shotRedact = true
    /// 链接分流
    public var links = LinkSettings()
    public var ai = AISettings()
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        ambientFormat = try c.decodeIfPresent(Bool.self, forKey: .ambientFormat) ?? false
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        secretClipMinutes = try c.decodeIfPresent(Int.self, forKey: .secretClipMinutes) ?? 60
        hotEdge = try c.decodeIfPresent(Bool.self, forKey: .hotEdge) ?? true
        edgeLeft = try c.decodeIfPresent(Bool.self, forKey: .edgeLeft) ?? false
        edgeHandle = try c.decodeIfPresent(Bool.self, forKey: .edgeHandle) ?? true
        handleY = try c.decodeIfPresent(Double.self, forKey: .handleY) ?? 0.5
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        shotHotkey = try c.decodeIfPresent(Bool.self, forKey: .shotHotkey) ?? true
        panelKey = (try? c.decodeIfPresent(KeyCombo.self, forKey: .panelKey)) ?? KeyCombo.defaultPanel
        shotKey = (try? c.decodeIfPresent(KeyCombo.self, forKey: .shotKey)) ?? KeyCombo.defaultShot
        shotRedact = try c.decodeIfPresent(Bool.self, forKey: .shotRedact) ?? true
        links = (try? c.decodeIfPresent(LinkSettings.self, forKey: .links)) ?? LinkSettings()
        ai = try c.decodeIfPresent(AISettings.self, forKey: .ai) ?? AISettings()
    }
}

public enum Text {
    public static func firstLine(_ s: String, max: Int) -> String? {
        for line in s.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t.count > max ? String(t.prefix(max)) + "…" : t }
        }
        return nil
    }

    /// 标题里不显示 ## ** ` 这些记号
    public static func stripMarks(_ s: String) -> String {
        var line = s.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") }.map(String.init) ?? s
        line = line.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") || line.hasPrefix(">") { line.removeFirst() }
        if line.hasPrefix("- ") || line.hasPrefix("* ") { line.removeFirst(2) }
        return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
    }

    public static func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}

/// 目标窗口的类别，决定怎么贴
public enum TargetKind: String {
    case chat, rich, terminal, ai, browser, other

    public static func of(bundle: String?) -> TargetKind {
        guard let b = bundle?.lowercased() else { return .other }
        let chat = ["com.tencent.xinwechat", "com.tencent.weworkmac", "com.tencent.qq", "com.alibaba.dingtalkmac",
                    "com.electron.lark", "com.bytedance.lark", "com.larksuite.larkapp", "ru.keepcoder.telegram", "com.hnc.discord",
                    "com.microsoft.teams", "com.microsoft.teams2", "com.apple.mobilesms", "com.tinyspeck.slackmacgap",
                    "com.tencent.meeting", "com.netease.macmail"]
        let rich = ["com.apple.mail", "com.microsoft.outlook", "com.microsoft.word", "com.apple.iwork.pages", "com.apple.notes",
                    "com.yinxiang.mac", "com.evernote.evernote", "com.microsoft.powerpoint", "com.apple.iwork.keynote", "com.apple.textedit",
                    "org.libreoffice.script"]
        let term = ["com.apple.terminal", "com.googlecode.iterm2", "org.tabby", "com.mitchellh.ghostty", "dev.warp.warp-stable",
                    "net.kovidgoyal.kitty", "com.github.wez.wezterm", "io.alacritty"]
        let ai = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.deepseek.dsh", "com.tencent.yuanbao",
                  "com.deepseek.chat"]
        let browser = ["com.google.chrome", "com.apple.safari", "com.brave.browser", "org.mozilla.firefox", "com.microsoft.edgemac",
                       "company.thebrowser.browser"]
        if chat.contains(b) { return .chat }
        if rich.contains(b) { return .rich }
        if term.contains(b) { return .terminal }
        if ai.contains(b) || b.contains("codex") { return .ai }
        if browser.contains(b) { return .browser }
        return .other
    }
}
