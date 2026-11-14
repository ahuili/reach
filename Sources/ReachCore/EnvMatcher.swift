import Foundation

public struct EnvCandidate: Equatable {
    public var itemId: String
    public var title: String
    public var folder: String
    public var value: String
    public var masked: String
    public var score: Int
}

public struct EnvMatch {
    public var name: String
    public var candidates: [EnvCandidate]
    /// 这个项目以前定过用哪条
    public var boundItemId: String?
    public var best: EnvCandidate? {
        if let b = boundItemId, let c = candidates.first(where: { $0.itemId == b }) { return c }
        guard let first = candidates.first else { return nil }
        // 第一名明显领先才算自动匹配上
        if candidates.count == 1 || first.score - candidates[1].score >= 3 { return first }
        return nil
    }
}

/// 项目要哪些配置（环境变量名），在抽屉里找对应的 Key。只做匹配，放不放行由人决定。
public enum EnvMatcher {
    struct Provider { let keys: [String]; let words: [String]; let prefix: String? }

    static let providers: [Provider] = [
        Provider(keys: ["anthropic", "claude"], words: ["anthropic", "claude"], prefix: "sk-ant-"),
        Provider(keys: ["openai"], words: ["openai", "chatgpt", "gpt"], prefix: "sk-"),
        Provider(keys: ["deepseek"], words: ["deepseek"], prefix: "sk-"),
        Provider(keys: ["dashscope", "bailian", "qwen", "tongyi"], words: ["百炼", "dashscope", "bailian", "通义", "qwen"], prefix: "sk-"),
        Provider(keys: ["moonshot", "kimi"], words: ["moonshot", "kimi", "月之暗面"], prefix: "sk-"),
        Provider(keys: ["zhipu", "glm", "bigmodel"], words: ["智谱", "zhipu", "glm"], prefix: nil),
        Provider(keys: ["minimax"], words: ["minimax"], prefix: nil),
        Provider(keys: ["volc", "ark", "doubao"], words: ["火山", "方舟", "豆包", "volc", "doubao"], prefix: nil),
        Provider(keys: ["jina"], words: ["jina"], prefix: "jina_"),
        Provider(keys: ["bocha"], words: ["博查", "bocha"], prefix: "sk-"),
        Provider(keys: ["tavily"], words: ["tavily"], prefix: "tvly-"),
        Provider(keys: ["github", "gh"], words: ["github"], prefix: "gh"),
        Provider(keys: ["telegram", "tg"], words: ["telegram", "tg", "bot"], prefix: nil),
        Provider(keys: ["aliyun", "alibaba", "oss"], words: ["阿里云", "aliyun", "oss"], prefix: "LTAI"),
        Provider(keys: ["openrouter"], words: ["openrouter"], prefix: "sk-or-"),
        Provider(keys: ["gemini", "google"], words: ["gemini", "google"], prefix: "AIza"),
        Provider(keys: ["postgres", "pg", "database", "db"], words: ["postgres", "pgsql", "pg", "数据库", "rds", "database", "hologres"], prefix: nil),
        Provider(keys: ["mysql"], words: ["mysql", "数据库"], prefix: nil),
        Provider(keys: ["redis"], words: ["redis"], prefix: nil),
        Provider(keys: ["mongo"], words: ["mongo"], prefix: nil),
        Provider(keys: ["milvus"], words: ["milvus"], prefix: nil),
    ]

    static let stop: Set<String> = ["api", "key", "token", "secret", "url", "uri", "id", "base", "endpoint", "host", "port", "user",
                                    "username", "password", "pass", "pwd", "access", "app", "auth", "the", "my", "env", "prod", "dev"]

    static func wants(_ name: String) -> FieldKind {
        let n = name.lowercased()
        if n.hasSuffix("url") || n.hasSuffix("uri") || n.contains("endpoint") || n.contains("base_url") { return .url }
        if n.hasSuffix("host") { return .host }
        if n.hasSuffix("user") || n.hasSuffix("username") || n.hasSuffix("account") { return .account }
        return .secret
    }

    public static func match(names: [String], items: [Item], folders: [Folder], bindings: [String: String]) -> [EnvMatch] {
        let folderName = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        return names.map { name in
            let tokens = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let own = tokens.filter { !stop.contains($0) }
            let provs = providers.filter { p in p.keys.contains { own.contains($0) } }
            let want = wants(name)
            var cands: [EnvCandidate] = []
            for it in items where it.kind == .kept || Store.isCommon(it) {
                let hay = (it.title + "\n" + it.text + "\n" + (folderName[it.folderId ?? ""] ?? "")).lowercased()
                var score = 0
                for p in provs { if p.words.contains(where: { hay.contains($0.lowercased()) }) { score += 5 } }
                for t in own where t.count >= 3 && hay.contains(t) { score += 3 }
                if hay.contains(name.lowercased()) { score += 6 }
                guard score > 0 else { continue }
                let fields = FieldParser.parse(it.text, loose: true, ignoring: it.notSecret).filter { $0.kind == want || (want == .host && $0.kind == .url) }
                guard !fields.isEmpty else { continue }
                var pick = fields[0]
                if want == .secret {
                    for p in provs { if let pre = p.prefix, let f = fields.first(where: { $0.value.hasPrefix(pre) }) { pick = f; score += 4; break } }
                    // 变量名紧挨着的那个值优先
                    if let r = it.text.range(of: name), let f = fields.first(where: { $0.location >= it.text.distance(from: it.text.startIndex, to: r.upperBound) }) {
                        pick = f; score += 4
                    }
                }
                cands.append(EnvCandidate(itemId: it.id, title: it.displayTitle, folder: folderName[it.folderId ?? ""] ?? "",
                                          value: pick.value, masked: want == .secret ? SecretDetector.maskValue(pick.value) : pick.value,
                                          score: score + min(it.useCount, 3)))
            }
            cands.sort { $0.score > $1.score }
            return EnvMatch(name: name, candidates: Array(cands.prefix(5)), boundItemId: bindings[name])
        }
    }

    /// 把配置写进 .env：已有的替换，没有的追加。返回新内容。
    public static func mergeEnv(existing: String, values: [(String, String)]) -> String {
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (k, v) in values {
            let needsQuote = v.contains(" ") || v.contains("#") || v.contains("\"") || v.contains("$")
            let line = needsQuote ? "\(k)=\"\(v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" : "\(k)=\(v)"
            if let i = lines.firstIndex(where: {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("\(k)=") || t.hasPrefix("export \(k)=")
            }) { lines[i] = line } else { lines.append(line) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// .env 有没有被 git 忽略（粗略检查 .gitignore）
    public static func envIgnored(project: String, file: String = ".env") -> Bool? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: project + "/.git") else { return nil }
        guard let gi = try? String(contentsOfFile: project + "/.gitignore", encoding: .utf8) else { return false }
        return gi.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.contains { l in
            l == file || l == "/" + file || l == ".env*" || l == ".env.*" || l == "*.env" || l == ".env"
        }
    }
}
