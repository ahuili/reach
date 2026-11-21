import Foundation

// 就地候选：长按 ⌘V 在光标旁边出一排候选。这里只放能离线测的部分——排序和按键判定；界面和读光标在 App 里。

/// 光标所在的输入框是哪一种（从辅助功能读出来的角色、提示文字推断）
public enum InputField: String {
    case password, url, account, terminal, chat, other
}

public struct InlineContext {
    public var field: InputField
    public var target: TargetKind
    public var bundle: String?
    /// 窗口标题、App 名：和抽屉条目的标题、文件夹对得上就排前（浏览器里看网站名）
    public var hints: [String]
    public var now: Date
    public init(field: InputField, target: TargetKind, bundle: String? = nil, hints: [String] = [], now: Date = Date()) {
        self.field = field; self.target = target; self.bundle = bundle; self.hints = hints; self.now = now
    }

    /// 从输入框的角色和提示文字猜种类
    public static func field(role: String?, subrole: String?, texts: [String], target: TargetKind) -> InputField {
        if subrole == "AXSecureTextField" { return .password }
        let t = texts.joined(separator: " ").lowercased()
        if ["password", "密码", "口令", "passcode"].contains(where: t.contains) { return .password }
        if target == .browser, ["address", "地址", "网址", "smart search", "url", "location"].contains(where: t.contains) { return .url }
        if ["email", "e-mail", "邮箱", "用户名", "账号", "帐号", "username", "user name", "login", "account"].contains(where: t.contains) { return .account }
        if target == .terminal { return .terminal }
        if target == .chat || target == .ai { return .chat }
        _ = role
        return .other
    }
}

public struct InlineCandidate: Equatable {
    public var itemId: String
    /// 只贴其中一项（密码、账号、网址）时是那一项的值；nil = 整条
    public var value: String?
    public var secret: Bool
    public var title: String
    /// 第二行：出处
    public var detail: String
    public var ctype: ContentType
    public var score: Double
}

public enum InlineRank {
    public static let fresh: TimeInterval = 120

    public static func rank(_ items: [Item], folders: [Folder], ctx: InlineContext, limit: Int = 5) -> [InlineCandidate] {
        let folderName = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        let hints = ctx.hints.flatMap(words).filter { !generic.contains($0) }
        let noSecrets = ctx.field != .password && (ctx.target == .chat || ctx.target == .ai)
        var out: [InlineCandidate] = []
        for it in items {
            if it.kind == .visit && ctx.field != .url { continue }
            let isSecret = it.sensitive || it.ctype == .secret || it.ctype == .credential
            if noSecrets && isSecret { continue }
            let folder = folderName[it.folderId ?? ""] ?? ""
            let hay = (it.title + "\n" + folder + "\n" + Text.truncate(it.text, 400)).lowercased()
            let site = hints.contains { hay.contains($0) }
            let fresh = it.kind == .clip && ctx.now.timeIntervalSince(it.createdAt) < fresh
            var s = 0.0
            if fresh { s += 100 }
            // 密码框、账号框里，和当前网站对得上比刚复制的更要紧
            if site { s += ctx.field == .password || ctx.field == .account ? 120 : 25 }
            if let b = ctx.bundle, let n = it.useByApp[b] { s += Double(min(n, 6)) * 5 }
            s += Double(min(it.useCount, 10))
            let touched = max(it.createdAt, it.lastUsedAt ?? .distantPast)
            s += max(0, 20 - ctx.now.timeIntervalSince(touched) / 3600)   // 一天内用过的往前

            var value: String?, secret = false, title = it.displayTitle
            switch ctx.field {
            case .password:
                // 只给密码：抽屉里带密码的条目（和网站对得上的排前），或者整条就是密钥的复制
                let fs = FieldParser.parse(it.text, loose: it.kind == .kept, ignoring: it.notSecret).filter { $0.kind == .secret }
                if let f = fs.first(where: { $0.name.map { n in hints.contains { n.lowercased().contains($0) } } ?? false }) ?? fs.first {
                    value = f.value; secret = true; s += 30
                    let name = it.title.isEmpty ? folder : it.title
                    title = (name.isEmpty ? f.displayLabel : "\(name) · \(f.displayLabel)") + "  " + SecretDetector.maskValue(f.value)
                } else { continue }
            case .account:
                let fs = FieldParser.parse(it.text, loose: it.kind == .kept, ignoring: it.notSecret).filter { $0.kind == .account }
                if let f = fs.first { value = f.value; title = f.value; s += 30 }
                else if it.ctype == .email || it.ctype == .phone { s += 30 }
                else if it.kind == .kept { continue }
            case .url:
                if it.ctype == .link || it.kind == .visit { s += 30 }
                else if let f = FieldParser.parse(it.text, loose: true).first(where: { $0.kind == .url }), it.kind == .kept { value = f.value; title = f.value; s += 20 }
                else { s -= 30 }
            case .terminal:
                if it.ctype == .command || it.ctype == .path || it.ctype == .image { s += 30 }
                if it.ctype == .secret { s -= 10 }
            case .chat, .other:
                break
            }
            // 抽屉里的东西多：没有一点相关（对得上网站、在这里贴过、输入框类型对得上）的不出来，免得挤掉刚复制的
            if it.kind == .kept, !site, (ctx.bundle.flatMap { it.useByApp[$0] } ?? 0) == 0, value == nil, !(it.useCount >= 3) { continue }
            // 候选条上永远不露出密钥原文
            if value == nil, it.ctype == .secret {
                title = (it.title.isEmpty ? "密钥" : it.title) + "  " + SecretDetector.maskValue(it.text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if value == nil, isSecret {
                title = SecretDetector.mask(title, loose: true, ignoring: it.notSecret)
            }
            out.append(InlineCandidate(itemId: it.id, value: value, secret: secret || (value == nil && isSecret), title: title,
                                       detail: source(it, folder: folder, now: ctx.now), ctype: it.ctype, score: s))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.itemId < $1.itemId }
        // 同样的内容只出一次
        var seen = Set<String>(), res: [InlineCandidate] = []
        for c in out {
            let key = c.value ?? items.first { $0.id == c.itemId }?.hash ?? c.itemId
            if seen.insert(key).inserted { res.append(c) }
            if res.count == limit { break }
        }
        return res
    }

    static let generic: Set<String> = ["google", "chrome", "safari", "微信", "新标签页", "new", "tab", "the", "and", "com", "www", "http", "https", "登录", "login"]

    /// 窗口标题拆成词：英文按非字母数字切、至少 3 个字母；中文整段（至少 2 个字）
    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { w in
            w.unicodeScalars.contains { $0.value > 0x2E80 } ? w.count >= 2 : w.count >= 3
        }
    }

    static func source(_ it: Item, folder: String, now: Date) -> String {
        switch it.kind {
        case .kept: return folder.isEmpty ? "抽屉" : "抽屉 · \(folder)"
        case .visit: return "点过的链接"
        case .clip:
            let s = now.timeIntervalSince(it.createdAt)
            let ago = s < 60 ? "刚刚" : s < 3600 ? "\(Int(s / 60)) 分钟前" : s < 86400 ? "\(Int(s / 3600)) 小时前" : "\(Int(s / 86400)) 天前"
            return ["最近复制", it.sourceApp, ago].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// 长按 ⌘V 的按键判定。短按照常粘贴（原样放一个 ⌘V 出去），按住超过阈值出候选条。
/// 纯状态机：输入按键事件，输出"吞掉还是放行"和要做的事，方便离线测。
public struct HoldPaste {
    public enum State: Equatable { case idle, pending, resolving, showing }
    public enum Key: Equatable {
        case vDown(repeat: Bool, shift: Bool, cmd: Bool, otherMods: Bool)
        case vUp
        case cmdUp
        case other(code: Int)
        case timer
        /// 候选算好了（数量）
        case ready(Int)
    }
    public enum Effect: Equatable {
        case startTimer, cancelTimer
        /// 放一个普通的 ⌘V 出去（短按，或者没有候选）
        case postPaste
        /// 读光标、算候选（异步，算好了回 .ready）
        case resolve
        case show, move(Int), choose(Int?), cancel, expand
    }

    public private(set) var state: State = .idle
    public private(set) var index = 0
    public private(set) var count = 0
    public init() {}

    /// 返回 (是否吞掉这个按键, 要做的事)
    public mutating func handle(_ k: Key) -> (swallow: Bool, effects: [Effect]) {
        switch (state, k) {
        case (.idle, .vDown(let rep, let shift, let cmd, let other)):
            // 只认单纯的 ⌘V；⇧⌘V（打开侧栏）、⌥⌘V 这些原样放过
            guard cmd, !shift, !other, !rep else { return (false, []) }
            state = .pending
            return (true, [.startTimer])
        case (.pending, .vDown(true, _, _, _)): return (true, [])
        case (.pending, .vUp), (.pending, .cmdUp):
            state = .idle
            return (k == .vUp, [.cancelTimer, .postPaste])
        case (.pending, .other):
            state = .idle
            return (false, [.cancelTimer, .postPaste])
        case (.pending, .timer):
            state = .resolving
            return (true, [.resolve])
        case (.resolving, .vDown), (.resolving, .vUp): return (true, [])
        case (.resolving, .cmdUp), (.resolving, .other):
            // 还没算好就松手了：当短按处理
            state = .idle
            return (false, [.postPaste])
        case (.resolving, .ready(let n)):
            guard n > 0 else { state = .idle; return (true, [.postPaste]) }
            state = .showing; index = 0; count = n
            return (true, [.show])
        case (.showing, .vDown(let rep, let shift, _, _)):
            if rep { return (true, []) }
            index = (index + (shift ? count - 1 : 1)) % count
            return (true, [.move(index)])
        case (.showing, .vUp): return (true, [])
        case (.showing, .cmdUp):
            state = .idle
            return (false, [.choose(index)])
        case (.showing, .other(let code)):
            switch code {
            case 53: state = .idle; return (true, [.cancel])                      // Esc
            case 36, 76: state = .idle; return (true, [.choose(index)])            // 回车
            case 123: index = (index + count - 1) % count; return (true, [.move(index)])
            case 124: index = (index + 1) % count; return (true, [.move(index)])
            case 125: state = .idle; return (true, [.expand])                      // ↓ 展开成侧栏搜索
            default:
                if let n = Self.digit(code), n <= count { state = .idle; index = n - 1; return (true, [.choose(index)]) }
                return (true, [])
            }
        case (.showing, .timer), (.showing, .ready): return (true, [])
        default: return (false, [])
        }
    }

    /// 别处收起了候选条（点了别处、选了一项）
    public mutating func reset() { state = .idle; index = 0; count = 0 }

    static func digit(_ code: Int) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][code]
    }
}
