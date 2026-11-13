import Foundation

/// 截图认出来的字：哪些地方要打码，哪些东西值得一键拿走
public enum ShotText {
    public struct Finding: Equatable {
        public var label: String
        public var icon: String
        public var value: String
    }

    /// 一行字里密钥所在的范围（Key、密码、Token、连接串里的密码），截图时在这些位置打码
    public static func secretRanges(in line: String) -> [NSRange] {
        SecretDetector.find(in: line, loose: false).map(\.range)
    }

    private static let errRe = try! NSRegularExpression(pattern: "(Traceback|Exception|\\b[A-Za-z]*Error\\b|\\berror:|\\bFAILED\\b|\\bfatal:|panic:|错误|报错|失败|异常|command not found|No such file|Permission denied|ECONNREFUSED|ETIMEDOUT|\\b[45]\\d\\d\\b (?:Not Found|Internal|Bad|Forbidden|Unauthorized))", options: [.caseInsensitive])
    private static let promptRe = try! NSRegularExpression(pattern: "^(?:\\S+\\s*)?[❯➜›»》❱$%#>]\\s*(.+)$")
    private static let phoneRe = try! NSRegularExpression(pattern: "(?<!\\d)(1[3-9]\\d{9}|\\+\\d{1,3}[ -]?\\d{3,4}[ -]?\\d{3,4}[ -]?\\d{3,4})(?!\\d)")

    /// 从认出来的几行字里挑出可以直接用的东西；带密钥的一律不给
    public static func findings(lines: [String]) -> [Finding] {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return [] }
        let full = clean.joined(separator: "\n")
        // 终端提示符后面的才是命令：「~/code/app ❯ npm run dev」「$ ls」
        let cmdText = clean.map { l -> String in
            let ns = l as NSString
            if let m = promptRe.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) { return ns.substring(with: m.range(at: 1)) }
            return l
        }.joined(separator: "\n")
        var out: [Finding] = []
        func add(_ label: String, _ icon: String, _ v: String) {
            let v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, !out.contains(where: { $0.value == v || $0.label == label }),
                  SecretDetector.find(in: v, loose: false).isEmpty else { return }
            out.append(Finding(label: label, icon: icon, value: v))
        }
        let fields = FieldParser.parse(full, loose: false)
        // 报错：从第一行带错误字样的开始，最多连带三行
        if let i = clean.firstIndex(where: { errRe.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) {
            add("报错", "exclamationmark.triangle", clean[i..<min(clean.count, i + 3)].joined(separator: "\n"))
        }
        if let c = FieldParser.parse(cmdText, loose: false).first(where: { $0.kind == .command }) { add("命令", "terminal", c.value.hasPrefix("$ ") ? String(c.value.dropFirst(2)) : c.value) }
        if let u = fields.first(where: { $0.kind == .url }) { add("网址", "link", u.value) }
        if let a = fields.first(where: { $0.kind == .account && $0.value.contains("@") }) { add("邮箱", "envelope", a.value) }
        if let m = phoneRe.firstMatch(in: full, range: NSRange(location: 0, length: (full as NSString).length)) {
            add("电话", "phone", (full as NSString).substring(with: m.range))
        }
        if let h = fields.first(where: { $0.kind == .host }) { add("地址", "server.rack", h.value) }
        out = Array(out.prefix(4))
        // 全部文字：密钥换成圆点
        let all = SecretDetector.mask(full)
        if all.count > 1 { out.append(Finding(label: "全部文字", icon: "text.viewfinder", value: all)) }
        return out
    }
}
