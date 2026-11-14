import Foundation

public enum AIError: Error, CustomStringConvertible {
    case notReady, http(Int, String), bad

    public var description: String {
        switch self {
        case .notReady: return "还没在设置里选 AI 模型"
        case .http(401, _), .http(403, _): return "API Key 不对或没有权限"
        case .http(let c, let b): return "HTTP \(c) \(b)"
        case .bad: return "模型的回答读不懂"
        }
    }
}

/// 最简单的 OpenAI 兼容接口调用。发出去之前调用方必须先把密钥抹掉（SecretDetector.redact），图要先打码。
public struct AIClient {
    public let cfg: AISettings
    public init(_ cfg: AISettings) { self.cfg = cfg }

    public func complete(system: String, user: String, maxTokens: Int = 600, timeout: TimeInterval = 40) async throws -> String {
        try await chat([["role": "system", "content": system], ["role": "user", "content": user]], maxTokens: maxTokens, timeout: timeout)
    }

    /// messages 按 OpenAI 的格式：content 可以是字符串，也可以是 [{type: text}, {type: image_url}] 这样的数组
    public func chat(_ messages: [[String: Any]], maxTokens: Int = 600, temperature: Double = 0.2, timeout: TimeInterval = 40) async throws -> String {
        guard cfg.isReady else { throw AIError.notReady }
        var base = cfg.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.bad }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty { req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": cfg.model, "temperature": temperature, "max_tokens": maxTokens, "messages": messages]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "") }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { throw AIError.bad }
        // 有的服务把 content 给成数组
        if let text = msg["content"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = msg["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw AIError.bad
    }
}

/// 本机的 Magpie（把各家模型汇到一个本机地址上，不用 Key）
public enum Magpie {
    public struct Model: Identifiable, Hashable {
        public var id: String
        public var label: String
        public var vision: Bool
    }

    /// Magpie 写在 ~/.config/magpie/gateway.json 里的地址，没有就用默认端口
    public static func baseURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let f = home.appendingPathComponent(".config/magpie/gateway.json")
        if let d = try? Data(contentsOf: f), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let addr = o["addr"] as? String, !addr.isEmpty {
            return "http://\(addr.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1"))/v1"
        }
        return "http://127.0.0.1:3425/v1"
    }

    public static var installed: Bool {
        FileManager.default.fileExists(atPath: "/Applications/magpie.app") || FileManager.default.fileExists(atPath: "/Applications/Magpie.app")
            || FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/magpie").path)
    }

    public static func parseModels(_ data: Data) -> [Model] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let arr = o["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let label = (m["magpie_label"] as? String) ?? (m["display_name"] as? String) ?? id
            let input = ((m["modalities"] as? [String: Any])?["input"] as? [String]) ?? []
            return Model(id: id, label: label, vision: input.contains("image"))
        }
    }

    /// 读模型列表；Magpie 没开时返回空
    public static func models(timeout: TimeInterval = 2) async -> [Model] {
        guard let url = URL(string: baseURL() + "/models") else { return [] }
        guard let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseModels(data)
    }
}

/// 截图里的字交给模型：原位翻译、看懂这张图
public enum ShotAI {
    /// 图里的字大多是中文就译成英文，否则译成中文
    public static func translateTarget(_ lines: [String]) -> String {
        var cjk = 0, latin = 0
        for l in lines { for u in l.unicodeScalars {
            if (0x4E00...0x9FFF).contains(u.value) { cjk += 1 } else if CharacterSet.letters.contains(u), u.isASCII { latin += 1 }
        } }
        return cjk * 2 >= latin && cjk > 0 ? "English" : "简体中文"
    }

    /// 一行值不值得翻：太短、纯数字符号、本来就是目标语言的不翻
    public static func worthTranslating(_ line: String, to target: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        let hasCJK = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if target == "简体中文" { return t.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) } || (!hasCJK) }
        return hasCJK
    }

    public static func translateSystem(target: String) -> String {
        """
        你是截图翻译。用户给你从一张截图里按行认出的文字（JSON 数组，每项是一行，可能有认字错误）。
        把每一行翻译成\(target)，结合上下文理解（相邻行常是同一句话被折行），但输出必须和输入一一对应、行数相同。
        专有名词、代码、命令、网址、数字、人名保持原样。界面按钮类短词用常见的界面译法。
        只输出一个 JSON 字符串数组，不要解释，不要代码块记号。
        """
    }

    /// 解析模型给回的逐行译文；行数对不上就返回 nil
    public static func parseLines(_ s: String, count: Int) -> [String]? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = t.firstIndex(of: "["), let b = t.lastIndex(of: "]"), a < b { t = String(t[a...b]) }
        guard let d = t.data(using: .utf8), let arr = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return nil }
        let out = arr.map { "\($0)" }
        return out.count == count ? out : nil
    }

    public static let explainSystem = """
    你是屏幕旁边的助手。用户在 Mac 上刚截了一张屏幕图想看懂它（命令按 macOS 给，不用列别的系统），下面是图里认出的文字（可能有认字错误；密钥已经换成 [API Key] 这样的占位），有时也附上图本身。
    先判断这是什么，再按类型回答，用简体中文，短而具体，不寒暄、不复述题目：
    - 外文内容：先给通顺的中文译文；再挑 1–4 个值得解释的词、缩写、梗或术语，每个一行「词 — 解释」。
    - 报错、日志：第一句说清是什么问题；再说最可能的原因；最后给下一步怎么做，命令放进 ``` 代码块。
    - 代码：说它在做什么、关键的一两点，有明显问题就指出。
    - 图表、表格、数据：说结论和最值得注意的数字。
    - 界面、设置页：说这里能做什么、用户多半要找的东西在哪。
    - 普通中文：一句话概括，再解释难懂的地方。
    不确定的地方直说不确定。整体尽量不超过 250 字（译文本身不算）。
    """

    /// 发给模型的那段文字：认出的字（密钥换圆点）+ 截图来自哪个 App
    public static func explainUser(lines: [String], app: String?) -> String {
        let text = SecretDetector.redact(lines.joined(separator: "\n"))
        var s = ""
        if let app, !app.isEmpty { s += "截图来自：\(app)\n" }
        s += text.isEmpty ? "（图里没认出文字）" : "图里的文字：\n\(text)"
        return s
    }

    /// 回答拆成普通段落和代码块，代码块单独显示、能一键复制
    public enum Segment: Equatable { case text(String), code(String) }
    public static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var buf: [String] = [], code: [String]? = nil
        func flush() { let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(.text(t)) }; buf = [] }
        for l in s.components(separatedBy: "\n") {
            if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(l) } else { buf.append(l) }
        }
        if let c = code, !c.isEmpty { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}
