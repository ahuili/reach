import AppKit
import UniformTypeIdentifiers
import SQLite3
import ReachCore

/// 一个能选的去处：显示用的名字、邮箱、颜色
struct LinkDest: Identifiable, Equatable {
    var target: LinkTarget
    var browserName: String
    /// 账号名，或「窗口组「公司」」
    var detail: String
    var email: String?
    var color: NSColor?
    var icon: NSImage?
    /// 账号头像（Chrome 系登录了 Google 账号才有）
    var avatar: NSImage?
    var id: String { target.key }
    var title: String { detail.isEmpty ? browserName : "\(browserName) · \(detail)" }
    /// 选择器里的大字：账号名 / 「公司」窗口 / 浏览器名
    var primary: String {
        if let g = target.group { return "「\(g)」窗口" }
        return detail.isEmpty ? browserName : detail
    }
    var secondary: String {
        if target.group != nil { return "\(browserName) · 组里最近用的窗口" }
        guard !detail.isEmpty else { return email ?? "" }
        return [browserName, email].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Chrome 系浏览器：数据目录在哪，账号用 --profile-directory 选
struct ChromiumFamily {
    let bundle: String
    let dir: String
    static let all = [
        ChromiumFamily(bundle: "com.google.Chrome", dir: "Google/Chrome"),
        ChromiumFamily(bundle: "com.brave.Browser", dir: "BraveSoftware/Brave-Browser"),
        ChromiumFamily(bundle: "com.microsoft.edgemac", dir: "Microsoft Edge"),
        ChromiumFamily(bundle: "com.vivaldi.Vivaldi", dir: "Vivaldi"),
        ChromiumFamily(bundle: "org.chromium.Chromium", dir: "Chromium"),
    ]
    static func of(_ bundle: String) -> ChromiumFamily? { all.first { $0.bundle.lowercased() == bundle.lowercased() } }
    var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dir)") }
}

enum LinkBrowsers {
    static let me = Bundle.main.bundleIdentifier ?? "me.ahuili.reach"
    private static let known = Set(["com.apple.safari", "org.mozilla.firefox", "company.thebrowser.browser", "company.thebrowser.dia", "com.kagi.kagimacos",
                                     "org.mozilla.firefoxdeveloperedition", "com.operasoftware.opera", "app.zen-browser.zen", "net.waterfox.waterfox"]
        + ChromiumFamily.all.map { $0.bundle.lowercased() })

    static func appURL(_ bundle: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) }
    static func name(_ bundle: String) -> String {
        guard let u = appURL(bundle) else { return bundle }
        return FileManager.default.displayName(atPath: u.path).replacingOccurrences(of: ".app", with: "")
    }
    private static var iconCache: [String: NSImage] = [:]
    static func icon(_ bundle: String) -> NSImage? {
        if let i = iconCache[bundle] { return i }
        guard let u = appURL(bundle) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: u.path)
        iconCache[bundle] = i
        return i
    }
    private static var avatarCache: [String: (Date, NSImage?)] = [:]
    static func avatar(_ f: ChromiumFamily, _ p: Profile) -> NSImage? {
        let u = f.root.appendingPathComponent(p.dir).appendingPathComponent(p.picture ?? "Google Profile Picture.png")
        let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let c = avatarCache[u.path], c.0 == m { return c.1 }
        let img = NSImage(contentsOf: u)
        avatarCache[u.path] = (m, img)
        return img
    }

    static func isRunning(_ bundle: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }

    /// 能打开网页的 App（不含手边自己）
    static func webApps() -> [String] {
        // 真正的浏览器既能开网址，也能开 html 文件；下载工具、笔记软件只登记了网址
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: .html).compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            // 编辑器、Playwright 自带的测试浏览器（藏在隐藏目录或缓存里）不算
            .filter { u in !u.path.contains("/Library/Caches/") && !u.pathComponents.contains { $0.hasPrefix(".") } }
            .compactMap { Bundle(url: $0)?.bundleIdentifier }
        var seen = Set<String>()
        return apps.filter { b in
            let l = b.lowercased()
            // 认识的浏览器，或者名字里写着 browser 又能开 html 的；下载工具、笔记软件也登记了网址，不算
            return l != me.lowercased() && (known.contains(l) || html.contains(l) && l.contains("browser")) && seen.insert(l).inserted
        }
    }

    struct Profile { let dir: String; let name: String; let email: String?; let domain: String?; let color: NSColor?; var picture: String? }

    /// Chrome 系某个浏览器的账号（读 Local State）
    static func chromiumProfiles(_ f: ChromiumFamily) -> [Profile] {
        guard let d = try? Data(contentsOf: f.root.appendingPathComponent("Local State")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cache = (j["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        let order = ((j["profile"] as? [String: Any])?["profiles_order"] as? [String]) ?? []
        return cache.compactMap { dir, v -> Profile? in
            if (v["is_ephemeral"] as? Bool) == true { return nil }
            let email = (v["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let domain = (v["hosted_domain"] as? String).flatMap { $0.isEmpty || $0 == "NO_HOSTED_DOMAIN" ? nil : $0 }
            var color: NSColor?
            if let c = (v["profile_highlight_color"] as? NSNumber)?.int64Value ?? (v["default_avatar_fill_color"] as? NSNumber)?.int64Value {
                let u = UInt32(truncatingIfNeeded: c)
                color = NSColor(srgbRed: CGFloat((u >> 16) & 0xFF) / 255, green: CGFloat((u >> 8) & 0xFF) / 255, blue: CGFloat(u & 0xFF) / 255, alpha: 1)
            }
            let pic = (v["gaia_picture_file_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(dir: dir, name: (v["name"] as? String) ?? dir, email: email, domain: domain, color: color, picture: pic)
        }.sorted { a, b in
            let ia = order.firstIndex(of: a.dir) ?? 99, ib = order.firstIndex(of: b.dir) ?? 99
            return ia != ib ? ia < ib : a.dir < b.dir
        }
    }

    /// Firefox 的配置
    static func firefoxProfiles() -> [String] {
        let ini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Firefox/profiles.ini")
        guard let s = try? String(contentsOf: ini, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline).compactMap { l in l.hasPrefix("Name=") ? String(l.dropFirst(5)) : nil }
    }

    /// 全部去处：浏览器 → 账号 → 窗口组。groups：各浏览器现在开着的窗口组
    static func destinations(groups: [String: [String]]) -> [LinkDest] {
        var out: [LinkDest] = []
        for b in webApps() {
            let bn = name(b), ic = icon(b)
            if let f = ChromiumFamily.of(b) {
                let ps = chromiumProfiles(f)
                for p in ps {
                    out.append(LinkDest(target: LinkTarget(browser: b, profile: p.dir), browserName: bn, detail: ps.count > 1 ? p.name : "", email: p.email, color: p.color, icon: ic, avatar: avatar(f, p)))
                }
                if ps.isEmpty { out.append(LinkDest(target: LinkTarget(browser: b), browserName: bn, detail: "", icon: ic)) }
                for g in groups[b] ?? [] {
                    out.append(LinkDest(target: LinkTarget(browser: b, group: g), browserName: bn, detail: "窗口「\(g)」", icon: ic))
                }
            } else if b.lowercased() == "org.mozilla.firefox" {
                let ps = firefoxProfiles()
                if ps.count > 1 { for p in ps { out.append(LinkDest(target: LinkTarget(browser: b, profile: p), browserName: bn, detail: p, icon: ic)) } }
                else { out.append(LinkDest(target: LinkTarget(browser: b), browserName: bn, detail: "", icon: ic)) }
            } else {
                out.append(LinkDest(target: LinkTarget(browser: b), browserName: bn, detail: "", icon: ic))
            }
        }
        return out
    }

    /// 账号 key → 企业域名
    static func hostedDomains() -> [String: String] {
        var out: [String: String] = [:]
        for f in ChromiumFamily.all where appURL(f.bundle) != nil {
            for p in chromiumProfiles(f) { if let d = p.domain { out[LinkTarget(browser: f.bundle, profile: p.dir).profileKey] = d } }
        }
        return out
    }
}

// MARK: 浏览历史：只数每个网站在各账号里的访问次数

enum LinkHistory {
    /// 网站 → 各账号的访问。只在本机读，不读标题，不落盘
    static func load(days: Int = 30) -> [String: SiteVisits] {
        var out: [String: SiteVisits] = [:]
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reach-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Chrome 时间：1601 年起的微秒
        let since = (Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        for f in ChromiumFamily.all where LinkBrowsers.appURL(f.bundle) != nil {
            for p in LinkBrowsers.chromiumProfiles(f) {
                let src = f.root.appendingPathComponent(p.dir).appendingPathComponent("History")
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                // 浏览器开着时文件被锁，拷一份读
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let copy = tmp.appendingPathComponent(UUID().uuidString)
                guard (try? FileManager.default.copyItem(at: src, to: copy)) != nil else { continue }
                let key = LinkTarget(browser: f.bundle, profile: p.dir).profileKey
                var db: OpaquePointer?
                guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); continue }
                var st: OpaquePointer?
                let sql = "SELECT u.url, v.visit_time FROM visits v JOIN urls u ON u.id = v.url WHERE v.visit_time > ? ORDER BY v.visit_time DESC LIMIT 100000"
                if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
                    sqlite3_bind_double(st, 1, since)
                    while sqlite3_step(st) == SQLITE_ROW {
                        guard let c = sqlite3_column_text(st, 0) else { continue }
                        let s = String(cString: c)
                        guard s.hasPrefix("http"), let u = URL(string: s) else { continue }
                        let h = LinkLogic.host(u)
                        guard !h.isEmpty else { continue }
                        out[h, default: SiteVisits()].add(key, at: sqlite3_column_double(st, 1))
                    }
                }
                sqlite3_finalize(st); sqlite3_close(db)
                try? FileManager.default.removeItem(at: copy)
            }
        }
        return out
    }
}

// MARK: Chrome 系的窗口（AppleScript；第一次用时系统问一次「自动化」权限）

struct BrowserWindow {
    let id: String
    let name: String
    let urls: [String]
    var group: String? { name.isEmpty ? nil : LinkLogic.group(of: name) }
}

enum LinkScript {
    /// 只在这条队列上跑 AppleScript（NSAppleScript 不能多线程同时用）
    static let queue = DispatchQueue(label: "reach.links.script")

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 跑一段脚本，出错返回 nil（没授权是 -1743）
    @discardableResult
    static func run(_ src: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { NSLog("Reach link script: \(err[NSAppleScript.errorNumber] ?? "") \(err[NSAppleScript.errorMessage] ?? "")") }
        return err == nil ? (r?.stringValue ?? "") : nil
    }

    private static let RS = "\u{1E}", US = "\u{1F}"

    /// 正在运行的 Chrome 系浏览器的普通窗口，从前到后
    static func windows(_ bundle: String) -> [BrowserWindow]? {
        guard LinkBrowsers.isRunning(bundle) else { return [] }
        let src = """
        set RS to (ASCII character 30)
        set US to (ASCII character 31)
        set out to ""
        tell application id \(quote(bundle))
            repeat with w in windows
                set m to "normal"
                try
                    set m to (mode of w) as text
                end try
                if m is "normal" then
                set gn to ""
                try
                    set gn to given name of w
                end try
                if gn is missing value then set gn to ""
                set us_ to ""
                repeat with t in tabs of w
                    set us_ to us_ & US & (URL of t)
                end repeat
                set out to out & (id of w as text) & US & gn & us_ & RS
                end if
            end repeat
        end tell
        return out
        """
        guard let s = run(src) else { return nil }
        return s.components(separatedBy: RS).compactMap { row in
            let f = row.components(separatedBy: US)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return BrowserWindow(id: f[0], name: f[1], urls: Array(f.dropFirst(2)))
        }
    }

    /// 在指定窗口里开一个新标签，把窗口提到最前
    static func openTab(_ bundle: String, window id: String, url: String) -> Bool {
        run("""
        tell application id \(quote(bundle))
            set w to window id \(id)
            tell w to make new tab at end of tabs with properties {URL:\(quote(url))}
            set active tab index of w to (count of tabs of w)
            set index of w to 1
            activate
        end tell
        """) != nil
    }

    /// 新开一个窗口并起名（组里的窗口全关了时用）
    static func newNamedWindow(_ bundle: String, name: String, url: String) -> Bool {
        run("""
        tell application id \(quote(bundle))
            set w to make new window
            set URL of active tab of w to \(quote(url))
            try
                set given name of w to \(quote(name))
            end try
            activate
        end tell
        """) != nil
    }

    /// 已经开着这个网址的标签：切过去
    static func focus(_ bundle: String, window id: String, url: String) -> Bool {
        run("""
        tell application id \(quote(bundle))
            set w to window id \(id)
            set i to 0
            repeat with t in tabs of w
                set i to i + 1
                if (URL of t) is \(quote(url)) then
                    set active tab index of w to i
                    exit repeat
                end if
            end repeat
            set index of w to 1
            activate
        end tell
        """) != nil
    }

    /// 读回刚开的那个标签的网页标题（给「点过的链接」搜索用）
    static func title(_ bundle: String, url: String) -> String? {
        let r = run("""
        tell application id \(quote(bundle))
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if u is \(quote(url)) or u starts with \(quote(url)) then return title of t
                end repeat
            end repeat
        end tell
        return ""
        """)
        return r.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 关掉刚才开错的那个标签：只关网址还是那个的，从后往前找最新开的
    static func closeTab(_ bundle: String, url: String) -> Bool {
        run("""
        tell application id \(quote(bundle))
            repeat with w in windows
                set n to count of tabs of w
                repeat with i from n to 1 by -1
                    if (URL of tab i of w) is \(quote(url)) then
                        close tab i of w
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return ""
        """) == "ok"
    }
}

// MARK: 打开

enum LinkOpener {
    /// 按去处打开。绝不交给系统默认浏览器（默认浏览器就是手边自己，会转回来）
    static func open(_ url: URL, _ t: LinkTarget, windows: [BrowserWindow]?, done: @escaping (Bool) -> Void) {
        guard t.browser.lowercased() != LinkBrowsers.me.lowercased(), let app = LinkBrowsers.appURL(t.browser) else { done(false); return }
        let s = url.absoluteString
        if let g = t.group, ChromiumFamily.of(t.browser) != nil {
            LinkScript.queue.async {
                let ws = windows ?? LinkScript.windows(t.browser) ?? []
                let inGroup = ws.filter { $0.group == g }
                // 组里已经开着同一个网站的窗口优先，否则最前面的那个
                let h = LinkLogic.host(url)
                let pick = inGroup.first { $0.urls.contains { URL(string: $0).map(LinkLogic.host) == h } } ?? inGroup.first
                let ok = pick.map { LinkScript.openTab(t.browser, window: $0.id, url: s) } ?? LinkScript.newNamedWindow(t.browser, name: g, url: s)
                DispatchQueue.main.async { ok ? done(true) : launch(url, app: app, args: [], done: done) }
            }
            return
        }
        var args: [String] = []
        if let p = t.profile {
            if ChromiumFamily.of(t.browser) != nil { args = ["--profile-directory=\(p)"] }
            else if t.browser.lowercased() == "org.mozilla.firefox" { args = ["-P", p] }
        }
        launch(url, app: app, args: args, done: done)
    }

    private static func launch(_ url: URL, app: URL, args: [String], done: @escaping (Bool) -> Void) {
        if args.isEmpty {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, e in DispatchQueue.main.async { done(e == nil) } }
            return
        }
        // 带参数时要用 open -n：浏览器开着时参数会转给正在跑的那个，在指定账号里开新标签
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-na", app.path, "--args"] + args + [url.absoluteString]
        p.terminationHandler = { pr in DispatchQueue.main.async { done(pr.terminationStatus == 0) } }
        do { try p.run() } catch { done(false) }
    }
}
