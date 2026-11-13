import Foundation

// 链接分流：点了链接，去对的浏览器、对的账号、对的窗口。这里只放判断逻辑，开浏览器的部分在 App 里。

/// 一个去处：浏览器 + 账号（Chrome 系是 Profile 目录名，Firefox 是配置名）+ 窗口组（窗口名的第一个词）
public struct LinkTarget: Codable, Hashable {
    public var browser: String
    public var profile: String?
    public var group: String?
    public init(browser: String, profile: String? = nil, group: String? = nil) {
        self.browser = browser; self.profile = profile; self.group = group
    }
    public var key: String { [browser, profile ?? "", group ?? ""].joined(separator: "|") }
    public init?(key: String) {
        let f = key.components(separatedBy: "|")
        guard f.count == 3, !f[0].isEmpty else { return nil }
        self.init(browser: f[0], profile: f[1].isEmpty ? nil : f[1], group: f[2].isEmpty ? nil : f[2])
    }
    /// 账号这一层的 key（统计浏览历史用）
    public var profileKey: String { LinkTarget(browser: browser, profile: profile).key }
}

public struct LinkRule: Codable, Equatable, Identifiable {
    public var id: String
    /// 网站，可以带路径前缀：「x.com」「github.com/corp」
    public var site: String?
    /// 来源 App 的 bundle id
    public var source: String?
    public var sourceName: String?
    public var target: LinkTarget
    public var createdAt: Date
    public init(id: String = UUID().uuidString, site: String? = nil, source: String? = nil, sourceName: String? = nil, target: LinkTarget, createdAt: Date = Date()) {
        self.id = id; self.site = site; self.source = source; self.sourceName = sourceName; self.target = target; self.createdAt = createdAt
    }
}

public enum LinkUnknown: String, Codable, CaseIterable {
    /// 有把握就直接开，没把握再问（保守）
    case guess
    /// 每次都问
    case ask
    /// 直接开在默认去处
    case fallback
}

public enum LinkNotice: String, Codable, CaseIterable { case guessed, always, never }

/// 同一个网站连续选了同一个去处几次（够两次就记成规则）
public struct LinkStreak: Codable, Equatable {
    public var target: String
    public var count: Int
}

public struct LinkSettings: Codable, Equatable {
    public var enabled = false
    public var paused = false
    public var unknown = LinkUnknown.guess
    public var notice = LinkNotice.guessed
    public var fallback: LinkTarget?
    public var rules: [LinkRule] = []
    /// 打开分流之前的默认浏览器，关掉时还回去
    public var previousBrowser: String?
    public var streaks: [String: LinkStreak] = [:]
    /// 记下点过的链接（进搜索，留 30 天）
    public var recordVisits = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        unknown = (try? c.decodeIfPresent(LinkUnknown.self, forKey: .unknown)) ?? .guess
        notice = (try? c.decodeIfPresent(LinkNotice.self, forKey: .notice)) ?? .guessed
        fallback = try? c.decodeIfPresent(LinkTarget.self, forKey: .fallback)
        rules = (try? c.decodeIfPresent([LinkRule].self, forKey: .rules)) ?? []
        previousBrowser = try? c.decodeIfPresent(String.self, forKey: .previousBrowser)
        streaks = (try? c.decodeIfPresent([String: LinkStreak].self, forKey: .streaks)) ?? [:]
        recordVisits = (try? c.decodeIfPresent(Bool.self, forKey: .recordVisits)) ?? true
    }
}

/// 某个网站最近 30 天在各账号里的访问
public struct SiteVisits: Equatable {
    public var counts: [String: Int] = [:]
    /// 最近几次访问：时间（越大越新）和账号
    public var recent: [Double] = []
    public var recentKeys: [String] = []
    public init() {}

    public mutating func add(_ key: String, at t: Double) {
        counts[key, default: 0] += 1
        // 只留最新的 3 次
        if recent.count < 3 || t > (recent.min() ?? 0) {
            recent.append(t); recentKeys.append(key)
            if recent.count > 3, let i = recent.indices.min(by: { recent[$0] < recent[$1] }) { recent.remove(at: i); recentKeys.remove(at: i) }
        }
    }
}

public enum LinkLogic {
    // MARK: 剥跳转壳

    private static let wrapperParams = ["url", "q", "u", "target", "to", "dest", "redirect", "redirect_uri", "link"]

    /// Slack、Google、Outlook、知乎这类跳转页：按里面的真实网址判断。只剥网址参数里明写着目标的，不联网
    public static func unwrap(_ url: URL) -> URL {
        var cur = url
        for _ in 0..<3 {
            guard let host = cur.host?.lowercased(), let comps = URLComponents(url: cur, resolvingAgainstBaseURL: false) else { break }
            let isWrapper = host == "slack-redirect.slack.com"
                || (host.hasPrefix("www.google.") || host.hasPrefix("google.")) && comps.path == "/url"
                || host.hasSuffix("safelinks.protection.outlook.com")
                || ["l.facebook.com", "lm.facebook.com", "l.instagram.com", "link.zhihu.com", "link.juejin.cn", "link.csdn.net",
                    "www.jianshu.com", "out.reddit.com", "steamcommunity.com", "c.pc.qq.com", "weixin110.qq.com"].contains(host)
                    && wrapperParams.contains(where: { p in comps.queryItems?.contains { $0.name == p } ?? false })
                || host.contains("redirect")
            guard isWrapper else { break }
            let inner = wrapperParams.lazy.compactMap { p in comps.queryItems?.first { $0.name == p }?.value }
                .compactMap { URL(string: $0) }.first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            guard let inner else { break }
            cur = inner
        }
        return cur
    }

    // MARK: 记下来之前先擦掉

    private static let sensitiveParam = try! NSRegularExpression(pattern: "(token|key|secret|pass|pwd|sig|signature|auth|code|session|sid|ticket|credential|otp|nonce)", options: [.caseInsensitive])

    /// 点过的链接存进库之前：名字像 token、key、签名的参数值，以及整段像密钥的参数值、路径段，换成圆点
    public static func scrub(_ url: URL) -> String {
        let mark = "REACHMASKED"
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.user = nil; c.password = nil
        if let qs = c.queryItems {
            c.queryItems = qs.map { q in
                guard let v = q.value, !v.isEmpty else { return q }
                let byName = sensitiveParam.firstMatch(in: q.name, range: NSRange(location: 0, length: (q.name as NSString).length)) != nil
                return byName || SecretDetector.isWholeSecret(v) ? URLQueryItem(name: q.name, value: mark) : q
            }
        }
        let segs = c.path.split(separator: "/", omittingEmptySubsequences: false).map { SecretDetector.isWholeSecret(String($0)) ? mark : String($0) }
        c.path = segs.joined(separator: "/")
        if c.fragment.map({ $0.contains("token") || SecretDetector.isWholeSecret($0) }) == true { c.fragment = mark }
        return (c.string ?? url.absoluteString).replacingOccurrences(of: mark, with: "•••")
    }

    // MARK: 网站

    /// 网站名：小写、去掉 www.
    public static func host(_ url: URL) -> String {
        var h = url.host?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// 规则里的网站（可带路径前缀）是否盖住这个网址。子域名也算：x.com 盖住 mobile.x.com
    public static func siteCovers(_ site: String, _ url: URL) -> Bool {
        let s = site.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
        guard let sh = parts.first, !sh.isEmpty else { return false }
        let h = host(url)
        guard h == sh || h.hasSuffix("." + sh) else { return false }
        if parts.count > 1 {
            let path = url.path.lowercased()
            let prefix = "/" + parts[1]
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        return true
    }

    /// 给一个网址建议的网站规则：通常就是网站名；GitHub、GitLab 这类按组织分的带上第一段路径
    public static func suggestedSite(_ url: URL) -> String {
        let h = host(url)
        let byOrg = ["github.com", "gitlab.com", "gitee.com", "bitbucket.org", "huggingface.co"]
        if byOrg.contains(h), let first = url.pathComponents.dropFirst().first, !first.isEmpty, first != "/" {
            return h + "/" + first.lowercased()
        }
        return h
    }

    // MARK: 规则

    /// 越具体越优先：网站 + 来源 > 网站（路径越长越优先）> 来源。用户不用排顺序
    public static func match(_ rules: [LinkRule], url: URL, source: String?) -> LinkRule? {
        func score(_ r: LinkRule) -> Int? {
            if let s = r.site, !siteCovers(s, url) { return nil }
            if let src = r.source, src.lowercased() != source?.lowercased() { return nil }
            if r.site == nil && r.source == nil { return nil }
            var n = 0
            if let s = r.site { n += 1000 + s.count }
            if r.source != nil { n += r.site == nil ? 500 : 2000 }
            return n
        }
        return rules.compactMap { r in score(r).map { (r, $0) } }.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.createdAt < b.0.createdAt }?.0
    }

    /// 加一条规则：同样网站和来源的旧规则换掉
    public static func upsert(_ rules: inout [LinkRule], _ r: LinkRule) {
        rules.removeAll { ($0.site?.lowercased() ?? "") == (r.site?.lowercased() ?? "") && ($0.source?.lowercased() ?? "") == (r.source?.lowercased() ?? "") }
        rules.append(r)
    }

    /// 在选择器里选了「只这次」：同一个网站连续两次选同一个去处就记成规则，返回新规则
    public static func learn(_ s: inout LinkSettings, site: String, target: LinkTarget) -> LinkRule? {
        let k = target.key
        var st = s.streaks[site] ?? LinkStreak(target: k, count: 0)
        st = st.target == k ? LinkStreak(target: k, count: st.count + 1) : LinkStreak(target: k, count: 1)
        if st.count >= 2 {
            s.streaks[site] = nil
            let r = LinkRule(site: site, target: target)
            upsert(&s.rules, r)
            return r
        }
        s.streaks[site] = st
        // 只记最近 200 个网站
        if s.streaks.count > 200, let old = s.streaks.keys.sorted().first { s.streaks[old] = nil }
        return nil
    }

    // MARK: 推测（保守）

    public static let sureMinVisits = 10
    public static let sureShare = 0.95

    /// 推测去哪个账号。sure 不为空才直接开；ranked 给选择器排序用。
    /// domains：账号 key → Google Workspace 的企业域名
    public static func guess(url: URL, visits: SiteVisits?, domains: [String: String]) -> (sure: String?, ranked: [String]) {
        let h = host(url)
        // 企业域名对上，并且只有一个账号对得上
        let byDomain = domains.filter { !$0.value.isEmpty && (h == $0.value.lowercased() || h.hasSuffix("." + $0.value.lowercased())) }.map(\.key)
        var ranked = (visits?.counts ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        for k in byDomain.sorted().reversed() { ranked.removeAll { $0 == k }; ranked.insert(k, at: 0) }
        if byDomain.count == 1 { return (byDomain[0], ranked) }
        guard byDomain.isEmpty, let v = visits, let top = ranked.first, let n = v.counts[top] else { return (nil, ranked) }
        let total = v.counts.values.reduce(0, +)
        let lastThree = v.recentKeys.count >= 3 && v.recentKeys.allSatisfy { $0 == top }
        if n >= sureMinVisits, Double(n) / Double(total) >= sureShare, lastThree { return (top, ranked) }
        return (nil, ranked)
    }

    // MARK: 窗口组

    /// 窗口名的第一个词就是组名：「公司」「公司 客户A」「公司-周报」都属于「公司」
    public static func group(of windowName: String) -> String? {
        let seps = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-·|｜:：/、_—"))
        let first = windowName.components(separatedBy: seps).first { !$0.isEmpty }
        return first
    }
}
