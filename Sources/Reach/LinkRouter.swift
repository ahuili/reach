import AppKit
import SwiftUI
import ReachCore

/// 链接分流：手边当默认浏览器，接住每个链接，按规则 / 推测 / 你的选择转给对的浏览器、账号、窗口
final class LinkRouter {
    enum Kind: String { case off, paused, focus, rule, guess, ask, fallback }

    struct Decision {
        var kind: Kind
        var url: URL
        var target: LinkTarget?
        var rule: LinkRule?
        var ranked: [LinkDest] = []
        /// 排第一的是按浏览历史排上来的
        var hinted = false
    }

    /// 最近一次自动打开的，给「换」「记住」用
    struct Opened { let url: URL; let target: LinkTarget; let source: String?; let sourceName: String? }

    private let model: AppModel
    var testMode = false
    private(set) var visits: [String: SiteVisits] = [:]
    private(set) var domains: [String: String] = [:]
    private(set) var loadMS = 0
    /// 各浏览器现在开着的窗口组
    private(set) var groups: [String: [String]] = [:]
    private var timer: Timer?
    private let picker = LinkPicker()
    private let notice = LinkNoticePanel()
    /// 测试模式下记下「本来会开到哪」
    private(set) var testLog: [[String: Any]] = []

    init(model: AppModel) { self.model = model }

    private var s: LinkSettings {
        get { model.settings.links }
        set { model.settings.links = newValue }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// 后台重读浏览历史和账号
    func refresh(done: (() -> Void)? = nil) {
        guard s.enabled || testMode else { done?(); return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let t0 = Date()
            let v = LinkHistory.load(), d = LinkBrowsers.hostedDomains()
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            DispatchQueue.main.async { self?.visits = v; self?.domains = d; self?.loadMS = ms; done?() }
        }
        refreshGroups()
    }

    /// 读一下各浏览器开着的窗口组（要自动化权限）
    func refreshGroups(done: (() -> Void)? = nil) {
        // 没打开分流时不碰浏览器（会弹自动化权限）
        guard !testMode, s.enabled else { done?(); return }
        LinkScript.queue.async { [weak self] in
            var g: [String: [String]] = [:]
            for f in ChromiumFamily.all where LinkBrowsers.isRunning(f.bundle) {
                var names: [String] = []
                for w in LinkScript.windows(f.bundle) ?? [] { if let n = w.group, !names.contains(n) { names.append(n) } }
                if !names.isEmpty { g[f.bundle] = names }
            }
            DispatchQueue.main.async {
                // 关掉的组如果规则还在用，也留在列表里，选了会新开一个
                if let self {
                    for r in self.s.rules { if let gg = r.target.group, !(g[r.target.browser] ?? []).contains(gg) { g[r.target.browser, default: []].append(gg) } }
                    self.groups = g
                }
                done?()
            }
        }
    }

    func destinations() -> [LinkDest] { LinkBrowsers.destinations(groups: groups) }

    var fallbackTarget: LinkTarget {
        if let f = s.fallback, LinkBrowsers.appURL(f.browser) != nil { return f }
        if let p = s.previousBrowser, LinkBrowsers.appURL(p) != nil { return LinkTarget(browser: p) }
        return LinkTarget(browser: "com.apple.Safari")
    }

    func dest(_ t: LinkTarget) -> LinkDest? { destinations().first { $0.target == t } }

    func name(of t: LinkTarget) -> String {
        destinations().first { $0.target == t }?.title ?? {
            var n = LinkBrowsers.name(t.browser)
            if let g = t.group { n += " · 窗口「\(g)」" } else if let p = t.profile { n += " · \(p)" }
            return n
        }()
    }

    // MARK: 判断

    func decide(_ raw: URL, source: String?, forceAsk: Bool = false) -> Decision {
        let url = LinkLogic.unwrap(raw)
        var d = Decision(kind: .ask, url: url)
        guard s.enabled else { d.kind = .off; d.target = fallbackTarget; return d }
        if s.paused { d.kind = .paused; d.target = fallbackTarget; return d }
        let g = LinkLogic.guess(url: url, visits: visits[LinkLogic.host(url)], domains: domains)
        d.ranked = rank(destinations(), by: g.ranked)
        d.hinted = !g.ranked.isEmpty
        if forceAsk { return d }
        if let r = LinkLogic.match(s.rules, url: url, source: source) { d.kind = .rule; d.rule = r; d.target = r.target; return d }
        switch s.unknown {
        case .ask: break
        case .fallback: d.kind = .fallback; d.target = fallbackTarget
        case .guess:
            if let k = g.sure, let t = d.ranked.first(where: { $0.target.profileKey == k && $0.target.group == nil })?.target { d.kind = .guess; d.target = t }
        }
        return d
    }

    /// 推测的账号排前面，其余保持原来的顺序
    private func rank(_ ds: [LinkDest], by keys: [String]) -> [LinkDest] {
        ds.enumerated().sorted { a, b in
            let ia = a.element.target.group == nil ? keys.firstIndex(of: a.element.target.profileKey) : nil
            let ib = b.element.target.group == nil ? keys.firstIndex(of: b.element.target.profileKey) : nil
            switch (ia, ib) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: 接链接

    func handle(_ raw: URL, sourcePID: pid_t?) {
        let app = sourcePID.flatMap { NSRunningApplication(processIdentifier: $0) }
        var src = app?.bundleIdentifier, srcName = app?.localizedName as String?
        // 自己转发给自己的（比如侧栏里点链接）不算来源
        if src?.lowercased() == LinkBrowsers.me.lowercased() { src = nil; srcName = nil }
        handle(raw, source: src, sourceName: srcName, option: NSEvent.modifierFlags.contains(.option))
    }

    func handle(_ raw: URL, source src: String?, sourceName srcName: String?, option: Bool) {
        let d = decide(raw, source: src, forceAsk: option)
        switch d.kind {
        case .off, .paused: go(d.url, d.target!, source: src, sourceName: srcName, notice: false)
        case .ask where option: ask(d, source: src, sourceName: srcName)
        default: dedupe(d.url) { [weak self] found in
            guard let self, !found else { return }
            switch d.kind {
            case .rule: self.go(d.url, d.target!, source: src, sourceName: srcName, notice: self.s.notice == .always)
            case .guess, .fallback: self.go(d.url, d.target!, source: src, sourceName: srcName, notice: self.s.notice != .never)
            default: self.ask(d, source: src, sourceName: srcName)
            }
        }
        }
    }

    /// html 文件之类：交给默认去处
    func openFile(_ url: URL) {
        guard let app = LinkBrowsers.appURL(fallbackTarget.browser) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 同一个网址已经开着：切过去，不开第二个
    private func dedupe(_ url: URL, done: @escaping (Bool) -> Void) {
        guard !testMode else { done(false); return }
        let s = url.absoluteString
        LinkScript.queue.async {
            var found = false
            for f in ChromiumFamily.all where LinkBrowsers.isRunning(f.bundle) {
                if let w = (LinkScript.windows(f.bundle) ?? []).first(where: { $0.urls.contains(s) }) {
                    found = LinkScript.focus(f.bundle, window: w.id, url: s)
                    if found { break }
                }
            }
            DispatchQueue.main.async { done(found) }
        }
    }

    private var last: Opened?

    private func go(_ url: URL, _ t: LinkTarget, source: String?, sourceName: String?, notice show: Bool, then: (() -> Void)? = nil) {
        last = Opened(url: url, target: t, source: source, sourceName: sourceName)
        if testMode {
            testLog.append(["url": url.absoluteString, "target": t.key])
            record(url, t, source: source, sourceName: sourceName)
            then?(); return
        }
        LinkOpener.open(url, t, windows: nil) { [weak self] ok in
            guard let self else { return }
            if !ok {
                // 开不了（浏览器卸载了之类）：退回默认去处，再不行交给 Safari
                let fb = self.fallbackTarget
                if fb != t { LinkOpener.open(url, fb, windows: nil) { _ in } }
                self.model.toast("没能在 \(self.name(of: t)) 打开，改在 \(self.name(of: fb)) 打开了")
                return
            }
            self.record(url, t, source: source, sourceName: sourceName)
            if show { self.showNotice(for: url, t) }
            then?()
        }
    }

    // MARK: 问

    private func ask(_ d: Decision, source: String?, sourceName: String?, replacing: Opened? = nil) {
        guard !d.ranked.isEmpty else { go(d.url, fallbackTarget, source: source, sourceName: sourceName, notice: false); return }
        // 测试模式不弹面板，只记一笔
        if testMode { testLog.append(["url": d.url.absoluteString, "target": "ask"]); return }
        picker.show(url: d.url, sourceName: sourceName, sourceBundle: source, hinted: d.hinted, dests: d.ranked, site: LinkLogic.suggestedSite(d.url)) { [weak self] dest, remember in
            guard let self, let dest else { return }
            self.chose(d.url, dest.target, remember: remember, source: source, sourceName: sourceName, replacing: replacing)
        }
    }

    /// 在选择器里选了一个去处
    func chose(_ url: URL, _ t: LinkTarget, remember: LinkPicker.Remember, source: String?, sourceName: String?, replacing: Opened? = nil) {
        if let old = replacing, !testMode, ChromiumFamily.of(old.target.browser) != nil, old.target != t {
            let b = old.target.browser, u = old.url.absoluteString
            LinkScript.queue.async { _ = LinkScript.closeTab(b, url: u) }
        }
        go(url, t, source: source, sourceName: sourceName, notice: false)
        let site = LinkLogic.suggestedSite(url)
        let before = s.rules
        var ls = s
        var msg: String?
        switch remember {
        case .site:
            LinkLogic.upsert(&ls.rules, LinkRule(site: site, target: t)); ls.streaks[site] = nil
            msg = "以后 \(site) 都开在 \(name(of: t))"
        case .source:
            if let src = source {
                LinkLogic.upsert(&ls.rules, LinkRule(source: src, sourceName: sourceName, target: t))
                msg = "以后从 \(sourceName ?? src) 点的链接都开在 \(name(of: t))"
            }
        case .once:
            if replacing != nil {
                // 「换」是在纠正：直接记成这个网站的规则
                LinkLogic.upsert(&ls.rules, LinkRule(site: site, target: t)); ls.streaks[site] = nil
                msg = "以后 \(site) 都开在 \(name(of: t))"
            } else if LinkLogic.learn(&ls, site: site, target: t) != nil {
                msg = "连着两次都选了这里，以后 \(site) 都开在 \(name(of: t))"
            }
        }
        s = ls
        if let msg, !testMode {
            notice.show(msg, detail: "规则可以在 设置 › 链接分流 里删", dest: dest(t), actions: [("撤销", { [weak self] in self?.s.rules = before; self?.model.toast("撤销了") })])
        }
    }

    // MARK: 开完的提示：换 / 记住

    private func showNotice(for url: URL, _ t: LinkTarget) {
        guard let o = last else { return }
        let d = dest(t)
        notice.show("已在 \(d?.primary ?? name(of: t)) 打开", detail: [d?.detail.isEmpty == false ? d?.browserName : nil, LinkLogic.host(url)].compactMap { $0 }.joined(separator: " · "), dest: d, actions: [
            ("换", { [weak self] in self?.swap(o) }),
            ("记住", { [weak self] in
                guard let self else { return }
                let site = LinkLogic.suggestedSite(url)
                let before = self.s.rules
                LinkLogic.upsert(&self.s.rules, LinkRule(site: site, target: t))
                self.notice.show("以后 \(site) 都开在这里", detail: self.name(of: t), dest: d, actions: [("撤销", { [weak self] in self?.s.rules = before })])
            }),
        ])
    }

    /// 开错了：重新选，选好后关掉刚才那个标签
    private func swap(_ o: Opened) {
        var d = decide(o.url, source: o.source, forceAsk: true)
        // 刚才那个排到最后
        d.ranked.sort { a, b in a.target != o.target && b.target == o.target }
        ask(d, source: o.source, sourceName: o.sourceName, replacing: o)
    }

    // MARK: 点过的链接

    /// 记下来进搜索：网址先擦掉 token 之类，留 30 天；几分钟内又开同一个只更新
    private func record(_ url: URL, _ t: LinkTarget, source: String?, sourceName: String?) {
        guard s.enabled, s.recordVisits else { return }
        let text = LinkLogic.scrub(url)
        let store = model.store
        var it = store.visits.first { $0.text == text && Date().timeIntervalSince($0.createdAt) < 600 }
            ?? Item(kind: .visit, ctype: .link, text: text, sourceApp: sourceName, sourceBundle: source)
        it.openedIn = t.key
        it.createdAt = Date(); it.updatedAt = Date()
        it.expiresAt = Date().addingTimeInterval(30 * 86400)
        if source != nil { it.sourceApp = sourceName; it.sourceBundle = source }
        store.save(it)
        model.rebuild()
        // 过几秒把网页标题读回来，搜标题比搜网址好用
        guard !testMode, ChromiumFamily.of(t.browser) != nil else { return }
        let id = it.id, u = url.absoluteString, b = t.browser
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            LinkScript.queue.async {
                guard let title = LinkScript.title(b, url: u) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, var cur = self.model.store.items[id] else { return }
                    cur.title = SecretDetector.mask(title)
                    self.model.store.save(cur)
                    self.model.rebuild()
                }
            }
        }
    }

    /// 侧栏里点过的链接：按原来的去处再开（ask 时重新选）
    func reopen(_ it: Item, ask askAgain: Bool = false) {
        guard let url = URL(string: it.text) else { return }
        if askAgain { ask(decide(url, source: it.sourceBundle, forceAsk: true), source: it.sourceBundle, sourceName: it.sourceApp); return }
        go(url, it.openedIn.flatMap(LinkTarget.init(key:)) ?? fallbackTarget, source: it.sourceBundle, sourceName: it.sourceApp, notice: false)
    }

    // MARK: 设成默认浏览器 / 还回去

    static var currentDefault: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
    static var isDefault: Bool { currentDefault?.lowercased() == LinkBrowsers.me.lowercased() }

    /// 打开分流：记下原来的默认浏览器，把手边设成默认（系统会弹一次确认）
    func enable(done: @escaping (Bool) -> Void) {
        if let cur = Self.currentDefault, cur.lowercased() != LinkBrowsers.me.lowercased() { s.previousBrowser = cur }
        if s.fallback == nil, let p = s.previousBrowser {
            // 默认去处：原来默认浏览器的第一个账号
            s.fallback = destinations().first { $0.target.browser == p && $0.target.group == nil }?.target ?? LinkTarget(browser: p)
        }
        setDefault(Bundle.main.bundleURL) { [weak self] ok in
            guard let self else { return }
            self.s.enabled = ok
            if ok { self.refresh() }
            done(ok)
        }
    }

    /// 关掉分流：默认浏览器还给原来那个
    func disable(done: @escaping (Bool) -> Void) {
        s.enabled = false
        let back = s.previousBrowser.flatMap(LinkBrowsers.appURL) ?? LinkBrowsers.appURL("com.apple.Safari")
        guard Self.isDefault, let back else { done(true); return }
        setDefault(back, done: done)
    }

    private func setDefault(_ app: URL, done: @escaping (Bool) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { e1 in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { e2 in
                DispatchQueue.main.async {
                    let want = Bundle(url: app)?.bundleIdentifier?.lowercased()
                    done(e1 == nil && e2 == nil || Self.currentDefault?.lowercased() == want)
                }
            }
        }
    }

    // MARK: 调试

    func debugChoose(_ url: URL, index: Int, remember: LinkPicker.Remember, source: String?) -> LinkTarget? {
        let d = decide(url, source: source, forceAsk: true)
        guard d.ranked.indices.contains(index) else { return nil }
        chose(d.url, d.ranked[index].target, remember: remember, source: source, sourceName: source)
        return d.ranked[index].target
    }

    /// 测试用：把选择器和提示画成图片，看排版
    func debugSnap(_ url: URL, picker path: String?, notice npath: String?) {
        func save(_ v: some View, _ p: String) {
            let h = NSHostingView(rootView: v)
            h.frame = CGRect(origin: .zero, size: h.fittingSize)
            guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return }
            h.cacheDisplay(in: h.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: p))
        }
        let d = decide(url, source: "com.tinyspeck.slackmacgap", forceAsk: true)
        if let path { save(LinkPickerView(url: d.url, sourceName: "Slack", sourceBundle: "com.tinyspeck.slackmacgap", site: LinkLogic.suggestedSite(d.url), dests: Array(d.ranked.prefix(9)), hinted: d.hinted, state: LinkPickerState()) { _ in }, path) }
        if let npath, let t = d.ranked.first {
            save(LinkNoticeView(dest: t, text: "已在 \(t.primary) 打开", detail: [t.detail.isEmpty ? nil : t.browserName, LinkLogic.host(d.url)].compactMap { $0 }.joined(separator: " · "), actions: [("换", {}), ("记住", {})]), npath)
        }
    }

    /// 测试用：直接塞浏览历史和企业域名
    func debugSet(visits v: [String: SiteVisits]?, domains d: [String: String]?, groups g: [String: [String]]?) {
        if let v { visits = v }
        if let d { domains = d }
        if let g { groups = g }
    }
}

// MARK: 选择器

final class LinkPickerPanel: NSPanel {
    var onResign: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); onResign() }
}

final class LinkPickerState: ObservableObject {
    @Published var sel = 0
    @Published var remember = LinkPicker.Remember.once
}

final class LinkPicker {
    enum Remember: String { case once, site, source }

    private var panel: LinkPickerPanel?
    private var monitor: Any?
    private var finish: ((LinkDest?, Remember) -> Void)?

    func show(url: URL, sourceName: String?, sourceBundle: String? = nil, hinted: Bool = false, dests: [LinkDest], site: String, done: @escaping (LinkDest?, Remember) -> Void) {
        close(nil)
        finish = done
        let state = LinkPickerState()
        let ds = Array(dests.prefix(9))
        let view = LinkPickerView(url: url, sourceName: sourceName, sourceBundle: sourceBundle, site: site, dests: ds, hinted: hinted, state: state) { [weak self] i in
            self?.close(ds[i], state.remember)
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!
        let v = screen.visibleFrame
        let x = min(max(v.minX + 8, m.x - 24), v.maxX - size.width - 8)
        let y = min(max(v.minY + 8, m.y - size.height - 12), v.maxY - size.height - 8)
        let p = LinkPickerPanel(contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = host
        p.onResign = { [weak self] in self?.close(nil) }
        panel = p
        p.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel?.isKeyWindow == true else { return e }
            switch e.keyCode {
            case 53: self.close(nil)
            case 36, 76: if ds.indices.contains(state.sel) { self.close(ds[state.sel], state.remember) }
            case 125: state.sel = min(ds.count - 1, state.sel + 1)
            case 126: state.sel = max(0, state.sel - 1)
            case 48: // Tab：换「记住」的方式
                let all: [Remember] = sourceName == nil ? [.once, .site] : [.once, .site, .source]
                state.remember = all[((all.firstIndex(of: state.remember) ?? 0) + 1) % all.count]
            default:
                if let c = e.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= ds.count { self.close(ds[n - 1], state.remember) }
                else { return e }
            }
            return nil
        }
    }

    private func close(_ d: LinkDest?, _ r: Remember = .once) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        let p = panel, f = finish
        panel = nil; finish = nil
        p?.onResign = {}
        p?.orderOut(nil)
        f?(d, r)
    }
}

struct LinkPickerView: View {
    let url: URL
    let sourceName: String?
    var sourceBundle: String? = nil
    let site: String
    let dests: [LinkDest]
    /// 第一个是按习惯排上来的
    var hinted = false
    @ObservedObject var state: LinkPickerState
    let pick: (Int) -> Void

    private var host: String { LinkLogic.host(url) }
    private var rest: String {
        var s = url.path
        if let q = url.query, !q.isEmpty { s += "?" + q }
        return s == "/" ? "" : s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 要开的链接
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.brand.opacity(0.16))
                    Image(systemName: "link").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.brand)
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if !rest.isEmpty { Text(rest).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 8)
                if let s = sourceName {
                    HStack(spacing: 4) {
                        if let i = sourceBundle.flatMap(LinkBrowsers.icon) { Image(nsImage: i).resizable().frame(width: 14, height: 14) }
                        Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
            .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 11)

            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)

            // 去处
            VStack(spacing: 1) {
                ForEach(Array(dests.enumerated()), id: \.offset) { i, d in
                    Button { pick(i) } label: { row(i, d) }
                        .buttonStyle(.plain)
                        .onHover { if $0 { state.sel = i } }
                }
            }
            .padding(6)

            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)

            // 记住
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("记住").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 0) {
                        seg("只这次", .once)
                        seg(site.count > 24 ? String(site.prefix(23)) + "…" : site, .site)
                        if let s = sourceName { seg("\(s) 来的", .source) }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                HStack(spacing: 12) {
                    keyHint("↩", "打开"); keyHint("1–\(dests.count)", "直接选"); keyHint("⇥", "换记法"); keyHint("esc", "不开")
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 11)
        }
        .frame(width: 392)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    private func row(_ i: Int, _ d: LinkDest) -> some View {
        let on = state.sel == i
        return HStack(spacing: 10) {
            DestIcon(dest: d, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(d.primary).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if i == 0 && hinted {
                        Text("常用").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Palette.brandInk)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Palette.brand.opacity(0.55)))
                    }
                }
                if !d.secondary.isEmpty { Text(d.secondary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 6)
            Text("\(i + 1)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(on ? Palette.brandInk : .secondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Palette.brand.opacity(0.6) : Color.primary.opacity(0.06)))
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Palette.brand.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }

    private func seg(_ t: String, _ r: LinkPicker.Remember) -> some View {
        let on = state.remember == r
        return Button { state.remember = r } label: {
            Text(t).font(.system(size: 11.5, weight: on ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .fixedSize().padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Palette.raised : .clear)
                    .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func keyHint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.18)))
            Text(t).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}

/// 去处的图标：浏览器图标，右下角叠账号头像（没有头像就是账号颜色的小圆点），窗口组叠一个窗口标记
struct DestIcon: View {
    let dest: LinkDest
    var size: CGFloat = 28
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let i = dest.icon { Image(nsImage: i).resizable().interpolation(.high) }
                else { RoundedRectangle(cornerRadius: size * 0.22).fill(Color.secondary.opacity(0.2)) }
            }.frame(width: size, height: size)
            let b = size * 0.5
            if dest.target.group != nil {
                Image(systemName: "macwindow").font(.system(size: b * 0.55, weight: .bold)).foregroundStyle(.white)
                    .frame(width: b, height: b).background(Circle().fill(Palette.brand))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: b * 0.22, y: b * 0.18)
            } else if let a = dest.avatar {
                Image(nsImage: a).resizable().interpolation(.high).frame(width: b, height: b).clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: b * 0.22, y: b * 0.18)
            } else if !dest.detail.isEmpty {
                Text(String(dest.detail.prefix(1)).uppercased()).font(.system(size: b * 0.55, weight: .bold)).foregroundStyle(.white)
                    .frame(width: b, height: b).background(Circle().fill(dest.color.map { Color(nsColor: $0) } ?? .gray))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: b * 0.22, y: b * 0.18)
            }
        }
        .frame(width: size + size * 0.12, height: size + size * 0.1, alignment: .topLeading)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView(); v.material = .popover; v.state = .active; v.blendingMode = .behindWindow; return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: 开完的提示（带按钮）

final class LinkNoticePanel {
    private var panel: NSPanel?
    private var timer: Timer?

    func show(_ text: String, detail: String = "", dest: LinkDest? = nil, actions: [(String, () -> Void)]) {
        timer?.invalidate()
        panel?.orderOut(nil)
        let view = LinkNoticeView(dest: dest, text: text, detail: detail, actions: actions.map { a in (a.0, { [weak self] in self?.hide(); a.1() }) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        let p = NSPanel(contentRect: NSRect(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() { timer?.invalidate(); panel?.orderOut(nil); panel = nil }
}

struct LinkNoticeView: View {
    var dest: LinkDest? = nil
    let text: String
    var detail: String = ""
    let actions: [(String, () -> Void)]
    var body: some View {
        HStack(spacing: 11) {
            if let d = dest { DestIcon(dest: d, size: 26) }
            else {
                ZStack {
                    Circle().fill(Palette.brand.opacity(0.18))
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.brand)
                }.frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.system(size: 13, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 4)
            ForEach(Array(actions.enumerated()), id: \.offset) { i, a in
                let main = i == actions.count - 1
                Button(a.0) { a.1() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(main ? Palette.brandInk : Color.primary)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(main ? Palette.brand.opacity(0.85) : Color.primary.opacity(0.08)))
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 9)
        .frame(minWidth: 300, maxWidth: 440)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}
