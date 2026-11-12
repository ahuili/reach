import Foundation

/// 认出一段内容是什么：命令、报错、链接、账号……全部本机规则。
public enum Classifier {
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let urlOnly = rx("^(?:https?|ftp)://\\S+$")
    private static let emailOnly = rx("^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$")
    private static let phoneOnly = rx("^\\+?\\d[\\d\\- ]{6,16}\\d$")
    private static let pathOnly = rx("^(?:/|~/)[^\\n]+$")
    private static let cmdStart = rx("^(?:\\$ |sudo |ssh |cd |ls |git |npm |pnpm |yarn |npx |pip3? |python3? |docker |kubectl |curl |wget |brew |make |cargo |go |swift |mysql |psql |redis-cli |cat |grep |rm |cp |mv |mkdir |chmod |export |source |tar |open |claude |codex |uv )")
    private static let errRe = rx("(Traceback \\(most recent call last\\)|Exception|\\bError\\b|\\berror:|\\bFAILED\\b|\\bfatal:|panic:|✗|错误[:：]|报错|失败[:：]|Segmentation fault|command not found|No such file|Permission denied|ECONNREFUSED|ETIMEDOUT)", [])
    private static let codeRe = rx("(^\\s*(?:def |class |func |function |import |from \\S+ import |const |let |var |public |private |#include|package |SELECT |INSERT |UPDATE |CREATE )|[;{}]\\s*$|=>|^```)", [.anchorsMatchLines])

    public static func classify(_ raw: String) -> ContentType {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = t as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard !t.isEmpty else { return .text }
        if SecretDetector.isWholeSecret(t) { return .secret }
        let lines = t.split(whereSeparator: \.isNewline)
        if lines.count == 1 {
            if urlOnly.firstMatch(in: t, range: full) != nil { return .link }
            if emailOnly.firstMatch(in: t, range: full) != nil { return .email }
            if phoneOnly.firstMatch(in: t, range: full) != nil, t.filter(\.isNumber).count >= 7 { return .phone }
            if pathOnly.firstMatch(in: t, range: full) != nil, !t.contains("  ") { return .path }
        }
        if (t.hasPrefix("{") || t.hasPrefix("[")), let d = t.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil { return .json }
        if lines.count <= 4, lines.allSatisfy({ cmdStart.firstMatch(in: String($0), range: NSRange(location: 0, length: ($0 as Substring).utf16.count)) != nil }) { return .command }
        let fields = FieldParser.parse(t, loose: false)
        if fields.contains(where: { $0.kind == .secret }) && (fields.contains(where: { $0.kind == .account || $0.kind == .url || $0.kind == .host }) || lines.count <= 3) {
            return .credential
        }
        if errRe.firstMatch(in: t, range: full) != nil && (lines.count > 1 || t.count > 40) { return .error }
        if lines.count >= 2, lines.filter({ $0.contains("\t") }).count >= max(2, lines.count * 2 / 3) { return .table }
        let codeHits = codeRe.numberOfMatches(in: t, range: full)
        if codeHits >= 2 || (lines.count >= 3 && codeHits >= 1 && Double(codeHits) / Double(lines.count) > 0.2) { return .code }
        return .text
    }
}

/// Markdown 相关：判断、转成干净文字、转成带格式的 HTML。给"看着目标窗口贴"用。
public enum Markdown {
    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let heading = rx("^(#{1,6})\\s+(.+?)\\s*#*$")
    private static let bold = rx("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italic = rx("(?<![\\*\\w])\\*(?=\\S)([^\\*\\n]+?)(?<=\\S)\\*(?![\\*\\w])")
    private static let strike = rx("~~(.+?)~~")
    private static let code = rx("`([^`\\n]+)`")
    private static let link = rx("\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")
    private static let image = rx("!\\[([^\\]\\n]*)\\]\\(([^)\\s]+)\\)")
    private static let bullet = rx("^(\\s*)[-*+]\\s+(.*)$")
    private static let ordered = rx("^(\\s*)(\\d+)[.)]\\s+(.*)$")
    private static let quote = rx("^\\s*>\\s?(.*)$")
    private static let tableSep = rx("^\\s*\\|?\\s*:?-{2,}:?\\s*(\\|\\s*:?-{2,}:?\\s*)*\\|?\\s*$")
    private static let hr = rx("^\\s*([-*_])\\s*(\\1\\s*){2,}$")
    private static let task = rx("^\\[( |x|X)\\]\\s+")

    private static func sub(_ re: NSRegularExpression, _ s: String, _ tpl: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: tpl)
    }
    private static func hit(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// 这段文字是不是带着 Markdown 记号（AI 工具复制出来的典型样子）
    public static func looksMarkdown(_ text: String) -> Bool {
        var score = 0
        var inFence = false
        for l in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
            let s = String(l)
            if s.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); score += 2; continue }
            if inFence { continue }
            if hit(heading, s) != nil { score += 2 }
            if hit(bold, s) != nil { score += 2 }
            if hit(tableSep, s) != nil && s.contains("|") { score += 3 }
            if hit(code, s) != nil { score += 1 }
            if hit(link, s) != nil { score += 1 }
            if hit(bullet, s) != nil || hit(ordered, s) != nil { score += 1 }
            if score >= 3 { return true }
        }
        return score >= 3
    }

    static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func inlinePlain(_ s: String) -> String {
        var t = s
        t = sub(image, t, "$1")
        t = link.matches(in: t, range: NSRange(location: 0, length: (t as NSString).length)).reversed().reduce(t) { acc, m in
            let ns = acc as NSString
            let label = ns.substring(with: m.range(at: 1)), url = ns.substring(with: m.range(at: 2))
            return ns.replacingCharacters(in: m.range, with: label == url || url.hasPrefix("#") ? label : "\(label)（\(url)）")
        }
        t = sub(bold, t, "$2")
        t = sub(italic, t, "$1")
        t = sub(strike, t, "$1")
        t = sub(code, t, "$1")
        return t
    }

    /// 去掉 Markdown 记号，变成聊天窗口里看着干净的文字
    public static func toPlain(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for l in text.components(separatedBy: "\n") {
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { out.append(l); continue }
            if hit(tableSep, l) != nil && l.contains("-") && (l.contains("|") || out.last?.contains("｜") == true) { continue }
            if hit(hr, l) != nil { out.append("————————"); continue }
            if let m = hit(heading, l) { out.append(inlinePlain((l as NSString).substring(with: m.range(at: 2)))); continue }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2 {
                out.append(cells(l).map(inlinePlain).joined(separator: " ｜ ")); continue
            }
            if let m = hit(bullet, l) {
                let ns = l as NSString
                var body = ns.substring(with: m.range(at: 2))
                var mark = "•"
                if let t = hit(task, body) {
                    mark = (body as NSString).substring(with: t.range).contains("x") || (body as NSString).substring(with: t.range).contains("X") ? "☑" : "☐"
                    body = (body as NSString).substring(from: t.range.length)
                }
                out.append(ns.substring(with: m.range(at: 1)) + mark + " " + inlinePlain(body)); continue
            }
            if let m = hit(ordered, l) {
                let ns = l as NSString
                out.append(ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)) + ". " + inlinePlain(ns.substring(with: m.range(at: 3)))); continue
            }
            if let m = hit(quote, l) { out.append(inlinePlain((l as NSString).substring(with: m.range(at: 1)))); continue }
            out.append(inlinePlain(l))
        }
        // 压掉连续三行以上的空行
        var res: [String] = []
        var blanks = 0
        for l in out {
            if l.trimmingCharacters(in: .whitespaces).isEmpty { blanks += 1; if blanks > 1 { continue } } else { blanks = 0 }
            res.append(l)
        }
        return res.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inlineHTML(_ s: String) -> String {
        var t = esc(s)
        t = sub(image, t, "$1")
        t = sub(link, t, "<a href=\"$2\">$1</a>")
        t = sub(bold, t, "<b>$2</b>")
        t = sub(italic, t, "<i>$1</i>")
        t = sub(strike, t, "<s>$1</s>")
        t = sub(code, t, "<code style=\"font-family:Menlo,monospace;background:#f2f2f2;padding:1px 4px;border-radius:3px\">$1</code>")
        return t
    }

    /// 转成 HTML，贴进邮件、Word 时带上标题、加粗、列表、表格
    public static func toHTML(_ text: String) -> String {
        var html = ""
        var inFence = false
        var list: String? = nil
        var inTable = false
        var para: [String] = []
        func flushPara() { if !para.isEmpty { html += "<p>" + para.joined(separator: "<br>") + "</p>"; para = [] } }
        func closeList() { if let l = list { html += "</\(l)>"; list = nil } }
        func closeTable() { if inTable { html += "</table>"; inTable = false } }
        for l in text.components(separatedBy: "\n") {
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushPara(); closeList(); closeTable()
                html += inFence ? "</pre>" : "<pre style=\"font-family:Menlo,monospace;background:#f6f6f6;padding:8px;border-radius:4px\">"
                inFence.toggle(); continue
            }
            if inFence { html += esc(l) + "\n"; continue }
            if trimmed.isEmpty { flushPara(); closeList(); closeTable(); continue }
            if hit(tableSep, l) != nil && inTable { continue }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2 {
                flushPara(); closeList()
                let tag = inTable ? "td" : "th"
                if !inTable { html += "<table border=\"1\" cellpadding=\"4\" style=\"border-collapse:collapse\">"; inTable = true }
                html += "<tr>" + cells(l).map { "<\(tag)>\(inlineHTML($0))</\(tag)>" }.joined() + "</tr>"
                continue
            }
            closeTable()
            if hit(hr, l) != nil { flushPara(); closeList(); html += "<hr>"; continue }
            if let m = hit(heading, l) {
                flushPara(); closeList()
                let n = m.range(at: 1).length
                html += "<h\(n)>" + inlineHTML((l as NSString).substring(with: m.range(at: 2))) + "</h\(n)>"; continue
            }
            if let m = hit(bullet, l) {
                flushPara()
                if list != "ul" { closeList(); html += "<ul>"; list = "ul" }
                html += "<li>" + inlineHTML((l as NSString).substring(with: m.range(at: 2))) + "</li>"; continue
            }
            if let m = hit(ordered, l) {
                flushPara()
                if list != "ol" { closeList(); html += "<ol>"; list = "ol" }
                html += "<li>" + inlineHTML((l as NSString).substring(with: m.range(at: 3))) + "</li>"; continue
            }
            closeList()
            if let m = hit(quote, l) { para.append("<i>" + inlineHTML((l as NSString).substring(with: m.range(at: 1))) + "</i>"); continue }
            para.append(inlineHTML(l))
        }
        flushPara(); closeList(); closeTable()
        if inFence { html += "</pre>" }
        return html
    }

    /// 贴进终端前：去掉行首的 $ 提示符和结尾的换行（避免一贴就执行）
    public static func forTerminal(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.hasPrefix("$ ") || $0.hasPrefix("% ") || $0.hasPrefix("❯ ") }) {
            lines = lines.map { $0.count >= 2 && ($0.hasPrefix("$ ") || $0.hasPrefix("% ") || $0.hasPrefix("❯ ")) ? String($0.dropFirst(2)) : $0 }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只留代码块里的内容
    public static func codeBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var cur: [String]? = nil
        for l in text.components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = cur { blocks.append(c.joined(separator: "\n")); cur = nil } else { cur = [] }
            } else if cur != nil { cur!.append(l) }
        }
        return blocks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// 带空位的留存：{内容}、{正式/随意}
public enum Template {
    private static let re = try! NSRegularExpression(pattern: "\\{([^{}\\n\"':;=]{1,24})\\}")

    public struct Slot: Equatable { public var name: String; public var options: [String] }

    public static func slots(in text: String) -> [Slot] {
        // JSON、代码里的花括号不算
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("{") || t.contains("{\n") { return [] }
        let ns = text as NSString
        var seen: [String] = [], out: [Slot] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            guard !seen.contains(raw), !raw.contains("$"), raw.rangeOfCharacter(from: .letters) != nil else { continue }
            seen.append(raw)
            let opts = raw.contains("/") ? raw.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) } : []
            out.append(Slot(name: raw, options: opts))
        }
        return out
    }

    public static func fill(_ text: String, values: [String: String]) -> String {
        var t = text
        for (k, v) in values { t = t.replacingOccurrences(of: "{\(k)}", with: v) }
        return t
    }
}
