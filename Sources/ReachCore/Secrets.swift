import Foundation

public struct SecretSpan: Equatable {
    public var range: NSRange
    public var label: String
    public var value: String
}

/// 在本机用规则找出文字里的密码、Key、Token。不经过任何模型。
public enum SecretDetector {
    private struct Rule { let label: String; let re: NSRegularExpression; let group: Int; var sep = 0 }

    private static func rx(_ p: String, _ opt: NSRegularExpression.Options = []) -> NSRegularExpression {
        // 规则是写死的，写错了直接在开发期暴露
        try! NSRegularExpression(pattern: p, options: opt)
    }

    private static let strong: [Rule] = [
        Rule(label: "私钥", re: rx("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"), group: 0),
        Rule(label: "API Key", re: rx("(?<![A-Za-z0-9])(sk-[A-Za-z0-9_\\-]{16,})"), group: 1),
        Rule(label: "GitHub Token", re: rx("(?<![A-Za-z0-9])(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"), group: 1),
        Rule(label: "AWS Key", re: rx("(?<![A-Za-z0-9])(AKIA[0-9A-Z]{16})(?![A-Za-z0-9])"), group: 1),
        Rule(label: "阿里云 Key", re: rx("(?<![A-Za-z0-9])(LTAI[A-Za-z0-9]{12,})"), group: 1),
        Rule(label: "Google Key", re: rx("(?<![A-Za-z0-9])(AIza[0-9A-Za-z_\\-]{30,})"), group: 1),
        Rule(label: "Slack Token", re: rx("(?<![A-Za-z0-9])(xox[abprs]-[A-Za-z0-9\\-]{10,})"), group: 1),
        Rule(label: "JWT", re: rx("(?<![A-Za-z0-9])(eyJ[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,}\\.[A-Za-z0-9_\\-]{8,})"), group: 1),
        Rule(label: "Bot Token", re: rx("(?<![0-9])(\\d{8,10}:[A-Za-z0-9_\\-]{30,})"), group: 1),
        Rule(label: "Token", re: rx("(?<![A-Za-z0-9])((?:jina|pt|cr|sds|pat|hf|glpat|npm|pk|rk|tok|key|ak|app)[_\\-][A-Za-z0-9_\\-]{16,})"), group: 1),
        Rule(label: "密码", re: rx("://[^\\s:/@]+:([^\\s@/]{3,})@"), group: 1),
        Rule(label: "密码", re: rx("(?:password|passwd|pwd|密码|口令)\\s*([:=：]|是|为)?\\s*([^\\s,，;；\"'`]{4,})", [.caseInsensitive]), group: 2, sep: 1),
        Rule(label: "密钥", re: rx("(?:secret|token|api[_ \\-]?key|app[_ \\-]?secret|access[_ \\-]?key|密钥|令牌)\\s*(?:[:=：]|是|为)\\s*([^\\s,，;；\"'`]{6,})", [.caseInsensitive]), group: 1),
    ]

    private static let tokenRe = rx("(?<![A-Za-z0-9_\\-/.@:])([A-Za-z0-9_\\-+=!@#$%^&*~.}{\\[\\]|?]{6,})(?![A-Za-z0-9_\\-])")
    private static let emailRe = rx("^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$")
    private static let versionRe = rx("^[vV]?\\d+(\\.\\d+)+[A-Za-z0-9\\-]*$")

    static func classes(_ s: String) -> (lower: Bool, upper: Bool, digit: Bool, symbol: Bool, count: Int) {
        var l = false, u = false, d = false, y = false
        for ch in s.unicodeScalars {
            if CharacterSet.lowercaseLetters.contains(ch) { l = true }
            else if CharacterSet.uppercaseLetters.contains(ch) { u = true }
            else if CharacterSet.decimalDigits.contains(ch) { d = true }
            else { y = true }
        }
        return (l, u, d, y, [l, u, d, y].filter { $0 }.count)
    }

    static func entropy(_ s: String) -> Double {
        var freq: [Character: Double] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return -freq.values.reduce(0) { $0 + ($1 / n) * log2($1 / n) }
    }

    /// 一个孤立的词像不像密码。loose 用于抽屉里的笔记（宁可多认），否则只认长的高熵串。
    static func looksLikePassword(_ t: String, loose: Bool) -> Bool {
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)
        if t.contains("://") || t.hasPrefix("http") || t.hasPrefix("www.") { return false }
        if emailRe.firstMatch(in: t, range: full) != nil || versionRe.firstMatch(in: t, range: full) != nil { return false }
        if t.hasPrefix("/") || t.hasPrefix("~") || t.hasPrefix("./") || t.hasPrefix("--") { return false }
        let c = classes(t)
        if t.count >= 20 {
            guard c.count >= 3, entropy(t) > 3.6 else { return false }
            // 文件名（xxx.docx）不算
            if t.range(of: "\\.[A-Za-z0-9]{1,5}$", options: .regularExpression) != nil, !t.hasSuffix("=") { return false }
            // UUID、容器名这类用 - _ . 分成好几段的标识符不算，除非大小写数字俱全（像 base64）
            let seps = t.filter { $0 == "-" || $0 == "_" || $0 == "." }.count
            if seps >= 2 && !(c.lower && c.upper && c.digit) { return false }
            return true
        }
        guard loose, t.count >= 8, t.count <= 40, c.digit else { return false }
        // 像文件名、域名、带点的标识符的不算
        if t.contains(".") && !c.upper { return false }
        let pureSym = t.unicodeScalars.filter { !CharacterSet.alphanumerics.contains($0) }
        if pureSym.allSatisfy({ $0 == "_" || $0 == "-" || $0 == "." }) && !(c.lower && c.upper) { return false }
        return (c.lower && c.upper && c.digit) || (c.symbol && c.count >= 3)
    }

    public static func find(in text: String, loose: Bool = false, ignoring: [String] = []) -> [SecretSpan] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var spans: [SecretSpan] = []
        for r in strong {
            for m in r.re.matches(in: text, range: full) {
                let rg = m.range(at: r.group)
                guard rg.location != NSNotFound, rg.length > 0 else { continue }
                let v = ns.substring(with: rg)
                if r.label == "密码" || r.label == "密钥" {
                    if v.hasPrefix("http") || v.hasPrefix("：") || v.hasPrefix(":") { continue }
                    // 「修改密码功能已上线」这类句子不是密码：值里有中文的不算
                    if v.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) { continue }
                    // 复制历史里（非 loose）没有冒号等分隔时，必须带数字或符号才算，免得把 "password reset" 的 reset 当密码
                    if r.sep > 0, m.range(at: r.sep).location == NSNotFound, !loose {
                        let c = classes(v)
                        if !(c.digit || c.symbol) { continue }
                    }
                }
                spans.append(SecretSpan(range: rg, label: r.label, value: v))
            }
        }
        for m in tokenRe.matches(in: text, range: full) {
            let rg = m.range(at: 1)
            let v = ns.substring(with: rg)
            if looksLikePassword(v, loose: loose) { spans.append(SecretSpan(range: rg, label: v.count >= 20 ? "密钥" : "密码", value: v)) }
        }
        // 合并重叠，保留先命中的（规则靠前的更具体）
        var out: [SecretSpan] = []
        for s in spans.sorted(by: { $0.range.location < $1.range.location }) {
            if ignoring.contains(s.value) { continue }
            if let last = out.last, NSIntersectionRange(last.range, s.range).length > 0 {
                let generic: (String) -> Bool = { $0 == "密码" || $0 == "密钥" }
                if generic(last.label) && !generic(s.label) { out[out.count - 1] = s }
                continue
            }
            out.append(s)
        }
        return out
    }

    /// 整段内容就是一个密钥（复制了一个 Key 或密码）
    public static func isWholeSecret(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return false }
        let spans = find(in: t)
        return spans.contains { $0.range.length >= (t as NSString).length - 2 }
    }

    public static func maskValue(_ v: String) -> String {
        if v.count >= 16 {
            return String(v.prefix(3)) + "••••••" + String(v.suffix(4))
        }
        return "••••••"
    }

    /// 列表里分辨用：长的露头尾，短的（多是密码）只说几位，不露字
    public static func maskHint(_ v: String) -> String {
        v.count >= 16 ? maskValue(v) : "•••••• \(v.count) 位"
    }

    /// 显示用：把密钥位置打码
    public static func mask(_ text: String, loose: Bool = false, ignoring: [String] = []) -> String {
        replace(text, loose: loose, ignoring: ignoring) { maskValue($0.value) }
    }

    /// 发给模型前用：把密钥位置换成占位，不留任何原文
    public static func redact(_ text: String) -> String {
        replace(text, loose: true, ignoring: []) { "[\($0.label)]" }
    }

    public static func replace(_ text: String, loose: Bool, ignoring: [String], with f: (SecretSpan) -> String) -> String {
        let spans = find(in: text, loose: loose, ignoring: ignoring)
        guard !spans.isEmpty else { return text }
        let ns = NSMutableString(string: text)
        for s in spans.reversed() { ns.replaceCharacters(in: s.range, with: f(s)) }
        return ns as String
    }
}

public enum FieldKind: String { case url, account, secret, host, command }

public struct Field: Equatable {
    public var kind: FieldKind
    public var label: String
    public var value: String
    public var location: Int
    /// 一条里有好几个密钥时，从上下文取的名字（同一行前面的字，或上面一行的小标题），用来分清哪个是哪个
    public var name: String? = nil

    /// 选项里显示：「OpenAI」API Key
    public var displayLabel: String { name.map { "「\($0)」\(label)" } ?? label }
}

/// 把一条笔记拆成可以单独贴的字段：网址、账号、密码、主机、命令
public enum FieldParser {
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let urlRe = rx("(?:https?|postgres(?:ql)?|mysql|redis|mongodb(?:\\+srv)?|ssh|ftp)://[^\\s\"'<>）)]+")
    private static let emailRe = rx("[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}")
    private static let accountRe = rx("(?:账号|帐号|账户|用户名|用户|user(?:name)?|account|login|管理员)\\s*(?:[:=：]|是|为)?\\s*([^\\s,，;；]{2,})", [.caseInsensitive])
    private static let hostRe = rx("(?<![0-9.])(\\d{1,3}(?:\\.\\d{1,3}){3}(?::\\d{2,5})?)(?![0-9])")
    private static let cmdRe = rx("^\\s*(?:\\$\\s+)?((?:ssh|mysql|psql|curl|docker|kubectl|redis-cli|mongosh|scp|rsync|git|npm|pnpm|yarn|make|python3?|pip3?|brew)\\s.+)$", [.anchorsMatchLines])

    public static func parse(_ text: String, loose: Bool = true, ignoring: [String] = []) -> [Field] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [Field] = []
        let secrets = SecretDetector.find(in: text, loose: loose, ignoring: ignoring)
        func inSecret(_ r: NSRange) -> Bool { secrets.contains { NSIntersectionRange($0.range, r).length > 0 } }
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in urlRe.matches(in: text, range: full) {
            out.append(Field(kind: .url, label: "网址", value: ns.substring(with: m.range), location: m.range.location)); taken.append(m.range)
        }
        for m in accountRe.matches(in: text, range: full) {
            let r = m.range(at: 1)
            guard free(r), !inSecret(r) else { continue }
            out.append(Field(kind: .account, label: "账号", value: ns.substring(with: r), location: r.location)); taken.append(r)
        }
        for m in emailRe.matches(in: text, range: full) where free(m.range) && !inSecret(m.range) {
            out.append(Field(kind: .account, label: "账号", value: ns.substring(with: m.range), location: m.range.location)); taken.append(m.range)
        }
        for m in hostRe.matches(in: text, range: full) where free(m.range(at: 1)) {
            out.append(Field(kind: .host, label: "主机", value: ns.substring(with: m.range(at: 1)), location: m.range.location))
        }
        for m in cmdRe.matches(in: text, range: full) {
            out.append(Field(kind: .command, label: "命令", value: ns.substring(with: m.range(at: 1)), location: m.range.location))
        }
        let names = secrets.count > 1 ? SecretNamer.names(for: secrets, in: text) : []
        for (i, s) in secrets.enumerated() {
            out.append(Field(kind: .secret, label: s.label, value: s.value, location: s.range.location, name: names.indices.contains(i) ? names[i] : nil))
        }
        return out.sorted { $0.location < $1.location }
    }
}

/// 给一条里的几个密钥起名字：同一行密钥前面的字（去掉"密码：""API_KEY="这类），没有就用上面紧挨着的小标题行
public enum SecretNamer {
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let lead = rx("^(?:[-*•·>#]+|\\d+[.)、]|export)\\s*", [.caseInsensitive])
    private static let urlTail = rx("[A-Za-z][A-Za-z0-9+.\\-]*://\\S*$")
    private static let trailSep = rx("[\\s:=：,，;；|/\\-—（(\\[【]+$")
    private static let trailWord = rx("(?:(?<![A-Za-z])|[\\s_\\-.]+)(?:api[\\s_\\-]?key|access[\\s_\\-]?key(?:[\\s_\\-]?id)?|secret[\\s_\\-]?(?:access[\\s_\\-]?)?key|app[\\s_\\-]?secret|client[\\s_\\-]?secret|secret|token|password|passwd|pwd|key|密码|口令|密钥|令牌|是|为|的)$", [.caseInsensitive])
    private static let accountLead = rx("^(?:账号|帐号|账户|用户名|用户|user(?:name)?|account|login)\\s*(?:[:=：]|是|为)?\\s*", [.caseInsensitive])

    static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    /// 前缀洗干净：去掉列表记号、行尾的分隔符和"密码""key"这类泛称
    public static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        t = strip(urlTail, t)
        t = strip(lead, t)
        while true {
            let n = strip(trailWord, strip(trailSep, t)).trimmingCharacters(in: .whitespaces)
            if n == t { break }
            t = n
        }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`*_#"))
        if t.count > 18 { t = "…" + String(t.suffix(17)) }
        return t
    }

    public static func names(for secrets: [SecretSpan], in text: String) -> [String?] {
        let ns = text as NSString
        var out: [String?] = secrets.map { s in
            let line = ns.lineRange(for: NSRange(location: s.range.location, length: 0))
            // 同一行前面如果还有一个密钥，从它后面开始算
            let start = secrets.map { NSMaxRange($0.range) }.filter { $0 > line.location && $0 <= s.range.location }.max() ?? line.location
            let before = clean(ns.substring(with: NSRange(location: start, length: s.range.location - start)))
            if !before.isEmpty { return before }
            // 这一行只有密钥（或"密码：xxx"）：在同一段里往上找。小标题（## 生产、生产：）优先，
            // 其次是紧挨着的一行，账号行去掉"账号"两个字（root@10.0.3.21 的密码），网址行太长不用
            var loc = line.location, near: String?, seenText = false, steps = 0
            while loc > 0, steps < 6 {
                let prev = ns.lineRange(for: NSRange(location: loc - 1, length: 0))
                let raw = ns.substring(with: prev).trimmingCharacters(in: .whitespacesAndNewlines)
                loc = prev.location
                if raw.isEmpty { if seenText { break } else { continue } }
                seenText = true; steps += 1
                if secrets.contains(where: { NSIntersectionRange($0.range, prev).length > 0 }) { break }
                let c = clean(strip(accountLead, raw))
                if raw.hasPrefix("#") || raw.hasSuffix(":") || raw.hasSuffix("：") {
                    if !c.isEmpty { return c }
                    break
                }
                if near == nil, !c.isEmpty, !raw.contains("://"), raw.count <= 40 { near = c }
            }
            return near
        }
        // 名字一样的，后面加上第几个
        var seen: [String: Int] = [:]
        let keys = zip(out, secrets).map { "\($0.0 ?? "")|\($0.1.label)" }
        let dup = Set(keys.filter { k in keys.filter { $0 == k }.count > 1 })
        for i in out.indices where dup.contains(keys[i]) {
            seen[keys[i], default: 0] += 1
            out[i] = (out[i].map { $0 + " " } ?? "") + "第\(seen[keys[i]]!)个"
        }
        return out
    }
}
