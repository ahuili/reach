import AppKit
import Combine
import ReachCore

/// 等你点头的一件事：Agent 要密钥、要写 .env、要存一条新凭据、要执行一步操作
struct Approval: Identifiable {
    enum Kind { case secret, env, save, tool }
    var id = UUID().uuidString
    var kind: Kind
    var agent: String
    var title: String
    var lines: [String]
    var warning: String?
    /// env：每个配置名的候选，以及当前选中的那条
    var matches: [EnvMatch] = []
    var choices: [String: String] = [:]
    var createdAt = Date()
    var respond: (_ allow: Bool, _ choices: [String: String]) -> Void
}

enum Tab: String { case recent, kept }

enum Row: Identifiable {
    case header(String, String)
    case day(String)
    case approval(Approval)
    case group(id: String, title: String, subtitle: String, count: Int, expanded: Bool)
    case folder(id: String, name: String, count: Int, expanded: Bool)
    case item(Item, indent: Bool)
    case note(String)

    var id: String {
        switch self {
        case .header(let t, _): return "h:" + t
        case .day(let t): return "d:" + t
        case .approval(let a): return "ap:" + a.id
        case .group(let id, _, _, _, _): return "g:" + id
        case .folder(let id, _, _, _): return "f:" + id
        case .item(let it, _): return "i:" + it.id
        case .note(let t): return "n:" + t
        }
    }
}

struct PasteOption: Identifiable {
    var id = UUID().uuidString
    var label: String
    var icon: String
    var detail: String
    var mode: PasteMode
    init(label: String, detail: String, icon: String = "doc.on.clipboard", mode: PasteMode) {
        self.label = label; self.detail = detail; self.icon = icon; self.mode = mode
    }
    init(label: String, icon: String, detail: String, mode: PasteMode) {
        self.label = label; self.detail = detail; self.icon = icon; self.mode = mode
    }
}

struct EditorState {
    var itemId: String?
    var title: String
    var text: String
    var folderId: String?
    var newFolder: String = ""
}

/// 放进抽屉那一页：要存的是哪几条，搜索框里打的字，选中第几项
struct SaveState {
    var ids: [String]
    var query = ""
    var index = 0
}

enum SaveChoice: Hashable {
    case new, each
    case append(String)
}

struct TemplateState {
    var item: Item
    var slots: [Template.Slot]
    var values: [String: String]
}

final class AppModel: ObservableObject {
    let store: Store
    @Published var query = "" { didSet { if query != oldValue { selection = nil; rebuild() } } }
    @Published var rows: [Row] = []
    @Published var selection: String?
    @Published var basket: [String] = []
    /// 侧栏两页：最近复制 / 抽屉。搜索时两页一起搜
    @Published var tab: Tab = .recent { didSet { if tab != oldValue { selection = nil; rebuild() } } }
    /// 抽屉页的文件夹筛选：nil = 全部，"@common" = 常用，否则是文件夹 id
    @Published var folderFilter: String? { didSet { if folderFilter != oldValue { selection = nil; rebuild() } } }
    /// 多选时 shift 点击的起点
    var anchor: String?
    @Published var approvals: [Approval] = []
    @Published var options: [PasteOption]?
    @Published var optionIndex = 0
    @Published var editor: EditorState?
    @Published var saving: SaveState?
    /// 管理文件夹的那一页
    @Published var managingFolders = false
    @Published var template: TemplateState?
    @Published var confirmSecret: (id: String, until: Date, app: String)?
    @Published var revealed: Set<String> = []
    @Published var focusTick = 0
    @Published var replyingTo: String?
    @Published var targetName = ""
    @Published var banner: String?
    @Published var busy: String?
    var targetBundle: String?
    var expandedGroups: Set<String> = []
    var collapsedGroups: Set<String> = []
    var expandedFolders: Set<String> = []
    var semantic: [String] = []

    // 由 AppDelegate 接上
    var paster: Paster!
    var shot: ShotController!
    var links: LinkRouter!
    var organizer: Organizer!
    /// SideNotes 里还没搬过来的笔记数（有才显示搬家提示）
    @Published var sideNotesHint: Int?
    var importSideNotes: () -> Void = {}
    var hidePanel: () -> Void = {}
    var toast: (String) -> Void = { _ in }

    init(store: Store) {
        self.store = store
        rebuild()
    }

    var settings: Settings {
        get { store.settings }
        set { store.settings = newValue; objectWillChange.send() }
    }

    // MARK: 列表

    func folderName(_ id: String?) -> String { store.folders.first { $0.id == id }?.name ?? "" }

    func rebuild() {
        var out: [Row] = []
        for a in approvals { out.append(.approval(a)) }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { out += tab == .recent ? recentRows() : keptRows() } else { out += searchRows(q) }
        rows = out
        let ids = selectable
        if selection == nil || !ids.contains(selection!) { selection = ids.first }
    }

    /// 最近复制：按天分段，同一段时间连着复制的收成一组
    private func recentRows() -> [Row] {
        var out: [Row] = []
        let clips = store.clips
        guard !clips.isEmpty else {
            return [.note("还没有复制记录。在任何地方按 ⌘C，内容就会出现在这里。")]
        }
        var order: [String] = [], byGroup: [String: [Item]] = [:]
        for c in clips.prefix(800) {
            let g = c.groupId ?? c.id
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(c)
        }
        var lastDay = ""
        for (i, g) in order.prefix(80).enumerated() {
            let its = byGroup[g]!
            let day = Fmt.day(its[0].createdAt)
            if day != lastDay { out.append(.day(day)); lastDay = day }
            if its.count == 1 { out.append(.item(its[0], indent: false)); continue }
            let expanded = (i == 0 && !collapsedGroups.contains(g)) || expandedGroups.contains(g)
            out.append(.group(id: g, title: groupTitle(g, its), subtitle: groupSubtitle(its), count: its.count, expanded: expanded))
            if expanded { for it in its { out.append(.item(it, indent: true)) } }
        }
        return out
    }

    /// 文件夹标签条用：（id, 名字, 条数），常用和全部排在前面
    var folderChips: [(id: String?, name: String, count: Int)] {
        let kept = store.kept
        var out: [(String?, String, Int)] = [(nil, "全部", kept.count)]
        let common = commonItems()
        if !common.isEmpty { out.append(("@common", "常用", common.count)) }
        for f in store.folders.sorted(by: { $0.order < $1.order }) {
            out.append((f.id, f.name, kept.filter { $0.folderId == f.id }.count))
        }
        let loose = kept.filter { it in it.folderId == nil || !store.folders.contains { $0.id == it.folderId } }.count
        if loose > 0, !store.folders.isEmpty { out.append(("@loose", "未归类", loose)) }
        return out.map { (id: $0.0, name: $0.1, count: $0.2) }
    }

    /// 抽屉：上面一排文件夹标签筛选，下面按最近用过排
    private func keptRows() -> [Row] {
        let kept = store.kept
        guard !kept.isEmpty else {
            return [.note("抽屉里还是空的。在最近复制里按 ⌘S 放进来一条，或按 ⌘N 直接写一条。")]
        }
        let its: [Item]
        switch folderFilter {
        case nil: its = kept
        case "@common": return commonItems().map { .item($0, indent: false) }
        case "@loose": its = kept.filter { it in it.folderId == nil || !store.folders.contains { $0.id == it.folderId } }
        case let f?: its = kept.filter { $0.folderId == f }
        }
        let sorted = its.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        if sorted.isEmpty { return [.note("这个文件夹是空的。")] }
        return sorted.map { .item($0, indent: false) }
    }

    func commonItems() -> [Item] {
        store.items.values.filter { Store.isCommon($0) || ($0.kind == .kept && $0.useCount >= 2) }
            .sorted { rank($0) > rank($1) }.prefix(8).map { $0 }
    }

    private func rank(_ it: Item) -> Double {
        var s = Double(min(it.useCount, 20)) * 2
        if let t = targetBundle, let n = it.useByApp[t] { s += Double(min(n, 6)) * 8 }
        if let u = it.lastUsedAt { s += max(0, 14 - Date().timeIntervalSince(u) / 86400) }
        return s
    }

    private func groupTitle(_ g: String, _ its: [Item]) -> String {
        if let n = store.groupNames[g], !n.isEmpty { return n }
        var count: [String: Int] = [:]
        for it in its { count[it.sourceApp ?? "未知", default: 0] += 1 }
        let top = count.sorted { $0.value > $1.value }.map(\.key)
        return top.count > 1 ? "\(top[0])、\(top[1])\(top.count > 2 ? " 等" : "")" : (top.first ?? "一组")
    }

    private func groupSubtitle(_ its: [Item]) -> String {
        var count: [ContentType: Int] = [:]
        for it in its { count[it.ctype, default: 0] += 1 }
        let parts = count.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value) \($0.key.label)" }
        return Fmt.time(its[0].createdAt) + " · " + parts.joined(separator: " · ")
    }

    private func searchRows(_ q: String) -> [Row] {
        let tokens = q.lowercased().split(separator: " ").map(String.init)
        var scored: [(Item, Double)] = []
        for it in store.items.values {
            let hay = it.searchable.lowercased()
            guard tokens.allSatisfy({ hay.contains($0) }) else { continue }
            var s = rank(it)
            let title = it.displayTitle.lowercased()
            if tokens.contains(where: { title.contains($0) }) { s += 30 }
            if title.hasPrefix(tokens[0]) { s += 20 }
            if it.kind == .kept { s += 15 } else { s += max(0, 15 - Date().timeIntervalSince(it.createdAt) / 86400 * 2) }
            scored.append((it, s))
        }
        scored.sort { $0.1 > $1.1 }
        let hits = scored.prefix(60).map(\.0)
        var out: [Row] = []
        let keptHits = hits.filter { $0.kind == .kept }, clipHits = hits.filter { $0.kind == .clip }, visitHits = hits.filter { $0.kind == .visit }
        if !keptHits.isEmpty { out.append(.header("抽屉", "\(keptHits.count)")); out += keptHits.map { .item($0, indent: false) } }
        if !clipHits.isEmpty { out.append(.header("最近复制", "\(clipHits.count)")); out += clipHits.map { .item($0, indent: false) } }
        if !visitHits.isEmpty { out.append(.header("点过的链接", "\(visitHits.count)")); out += visitHits.map { .item($0, indent: false) } }
        // 字面搜不到几条时，补上"意思相近"的
        let extra = semantic.compactMap { store.items[$0] }.filter { e in !hits.contains { $0.id == e.id } }
        if hits.count < 5, !extra.isEmpty {
            out.append(.header("意思相近", ""))
            out += extra.prefix(6).map { .item($0, indent: false) }
        }
        if hits.isEmpty && extra.isEmpty { out.append(.note("没有找到。")) }
        return out
    }

    var selectable: [String] {
        rows.compactMap { if case .item(let it, _) = $0 { return it.id } else { return nil } }
    }

    var selectedItem: Item? { selection.flatMap { store.items[$0] } }

    func move(_ d: Int) {
        let ids = selectable
        guard !ids.isEmpty else { return }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, i + d))]
        confirmSecret = nil
    }

    func toggleGroup(_ id: String, expanded: Bool) {
        if expanded { expandedGroups.remove(id); collapsedGroups.insert(id) } else { expandedGroups.insert(id); collapsedGroups.remove(id) }
        rebuild()
    }

    func toggleFolder(_ id: String, expanded: Bool) {
        if id == "@common" { toggleGroup(id, expanded: expanded); return }
        if expanded { expandedFolders.remove(id) } else { expandedFolders.insert(id) }
        rebuild()
    }

    // MARK: 显示

    func isRevealed(_ it: Item) -> Bool { revealed.contains(it.id) }

    func shown(_ text: String, _ it: Item) -> String {
        isRevealed(it) ? text : SecretDetector.mask(text, loose: it.kind == .kept, ignoring: it.notSecret)
    }

    func fields(_ it: Item) -> [Field] {
        guard it.ctype != .image, it.ctype != .file else { return [] }
        return FieldParser.parse(it.text, loose: it.kind == .kept, ignoring: it.notSecret)
    }

    // MARK: 操作

    func activate(_ it: Item, plain: Bool = false) {
        // 点过的链接：回车按原来的去处再开一次（→ 里可以贴网址、换个地方开）
        if it.kind == .visit, !plain { hidePanel(); links?.reopen(it); return }
        // 抽屉里账号密码类的，回车就是贴密码，不当成带空位的模板
        if !plain, it.kind == .kept, !it.sensitive, it.ctype != .credential, it.ctype != .secret {
            let slots = Template.slots(in: it.text)
            if !slots.isEmpty {
                template = TemplateState(item: it, slots: slots, values: Dictionary(uniqueKeysWithValues: slots.map { ($0.name, $0.options.first ?? "") }))
                return
            }
        }
        paster.paste(it, mode: plain ? .plain : .smart)
    }

    func openOptions() {
        guard let it = selectedItem else { return }
        options = paster.options(for: it)
        optionIndex = 0
    }

    /// "怎么贴"里按 ⌘C：只复制这一项，不贴、不收起侧栏
    func copyOption(_ i: Int) {
        guard let it = selectedItem, let o = options, o.indices.contains(i) else { return }
        paster.copyOnly(it, mode: o[i].mode, label: o[i].label)
    }

    func chooseOption(_ i: Int) {
        guard let it = selectedItem, let o = options, o.indices.contains(i) else { return }
        options = nil
        paster.paste(it, mode: o[i].mode)
    }

    func keep(_ it: Item) {
        guard it.kind == .clip else { toast("已经在抽屉里了"); return }
        keepQuietly(it)
        rebuild()
        toast("已放进抽屉")
    }

    private func keepQuietly(_ it: Item) {
        var k = it
        k.kind = .kept; k.expiresAt = nil; k.groupId = nil
        if k.ctype == .secret { k.sensitive = true }
        store.save(k)
        organizer.autoFile(k.id)
    }

    // MARK: 放进抽屉（⌘S）：存成新的一条，或加到抽屉里已有的一条后面

    /// 篮子里有东西就存整篮，否则存选中的这条
    func startSave(_ it: Item?) {
        let ids = basket.isEmpty ? (it.map { [$0.id] } ?? []) : basket
        guard !ids.isEmpty else { return }
        if ids.count == 1, store.items[ids[0]]?.kind == .kept { toast("已经在抽屉里了"); return }
        saving = SaveState(ids: ids)
    }

    /// 放进抽屉那一页的选项：新的一条、（多条时）每条单独存，再往下是抽屉里能接在后面的那些
    var saveChoices: [SaveChoice] {
        guard let s = saving else { return [] }
        var out: [SaveChoice] = [.new]
        if s.ids.count > 1 { out.append(.each) }
        let q = s.query.trimmingCharacters(in: .whitespaces).lowercased()
        let targets = store.kept
            .filter { !s.ids.contains($0.id) && $0.ctype != .image && $0.ctype != .file }
            .sorted { ($0.lastUsedAt ?? $0.updatedAt) > ($1.lastUsedAt ?? $1.updatedAt) }
            .filter { it in
                q.isEmpty || it.displayTitle.lowercased().contains(q) || folderName(it.folderId).lowercased().contains(q)
                    || SecretDetector.mask(it.text, loose: true, ignoring: it.notSecret).lowercased().contains(q)
            }
        out += targets.prefix(60).map { .append($0.id) }
        return out
    }

    /// 几条合成一段正文：图片用认出的字，文件用路径
    private func mergedText(_ items: [Item]) -> String {
        items.map { it -> String in
            switch it.ctype {
            case .image: return it.ocr ?? ""
            case .file: return (it.files ?? []).joined(separator: "\n")
            default: return it.text
            }
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// 正文改了以后重新认密钥和类型
    private func refresh(_ it: inout Item) {
        it.hash = store.vault.fingerprint(Data(it.text.utf8))
        let secrets = SecretDetector.find(in: it.text, loose: true, ignoring: it.notSecret)
        it.sensitive = !secrets.isEmpty
        it.ctype = secrets.isEmpty ? Classifier.classify(it.text) : (SecretDetector.isWholeSecret(it.text) ? .secret : .credential)
    }

    func finishSave(_ c: SaveChoice) {
        guard let s = saving else { return }
        saving = nil
        let items = s.ids.compactMap { store.items[$0] }
        guard !items.isEmpty else { return }
        switch c {
        case .new where items.count == 1:
            keep(items[0])
            selection = items[0].id
        case .each, .new where mergedText(items).isEmpty:
            let clips = items.filter { $0.kind == .clip }
            for it in clips { keepQuietly(it) }
            basket = []
            rebuild()
            toast(clips.isEmpty ? "选中的都已经在抽屉里了" : "已放进抽屉 \(clips.count) 条")
        case .new:
            var k = Item(kind: .kept, text: mergedText(items), origin: .manual)
            refresh(&k)
            store.save(k)
            organizer.autoFile(k.id)
            basket = []
            selection = k.id
            rebuild()
            toast("已合成一条放进抽屉")
        case .append(let id):
            guard var t = store.items[id] else { return }
            let add = mergedText(items)
            guard !add.isEmpty else { toast("图片和文件接不到已有的一条后面，可以单独放进抽屉"); return }
            t.text = t.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + add
            t.html = nil
            refresh(&t)
            store.save(t)
            basket = []
            rebuild()
            toast("已加到「\(Text.truncate(shown(t.displayTitle, t), 16))」后面")
        }
    }

    func remove(_ it: Item) {
        store.delete(it.id)
        basket.removeAll { $0 == it.id }
        rebuild()
    }

    func toggleBasket(_ it: Item) {
        if let i = basket.firstIndex(of: it.id) { basket.remove(at: i) } else { basket.append(it.id) }
        anchor = it.id
    }

    /// 拖的那条在篮子里：整篮一起拖
    func dropIds(_ id: String) -> [String] { basket.contains(id) ? basket : [id] }

    /// shift 点击：从上次点的那条到这条，全部放进篮子
    func basketRange(to it: Item) {
        let ids = selectable
        guard let a = anchor ?? selection, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: it.id) else { toggleBasket(it); return }
        for id in ids[min(i, j)...max(i, j)] where !basket.contains(id) { basket.append(id) }
        anchor = it.id
    }

    /// imagePaths：贴进终端时，截图换成临时文件路径（命令行 Agent 能读图）
    func basketText(imagePaths: Bool = false) -> String {
        basket.compactMap { store.items[$0] }.map { it in
            let src = [it.sourceApp, Fmt.time(it.createdAt)].compactMap { $0 }.joined(separator: " · ")
            var body = it.ctype == .image ? (it.ocr ?? "（图片）") : (it.ctype == .file ? (it.files ?? []).joined(separator: "\n") : it.text)
            if it.ctype == .image, imagePaths, let p = paster.shotFile(it) { body = p + ((it.ocr ?? "").isEmpty ? "" : "\n（图里的文字：\(Text.truncate(it.ocr!, 400))）") }
            return "【来自 \(src)】\n\(body)"
        }.joined(separator: "\n\n")
    }

    func newNote() {
        editor = EditorState(itemId: nil, title: "", text: "", folderId: selectedItem?.folderId ?? store.folders.first?.id)
    }

    func edit(_ it: Item) {
        editor = EditorState(itemId: it.id, title: it.title, text: it.text, folderId: it.folderId)
    }

    func saveEditor() {
        guard var e = editor else { return }
        let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { editor = nil; return }
        let newName = e.newFolder.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty { e.folderId = store.folder(named: newName).id }
        var it = e.itemId.flatMap { store.items[$0] } ?? Item(kind: .kept, text: text, origin: .manual)
        it.kind = .kept; it.expiresAt = nil; it.groupId = nil
        it.title = e.title.trimmingCharacters(in: .whitespaces)
        it.text = text
        it.folderId = e.folderId
        it.hash = store.vault.fingerprint(Data(text.utf8))
        let secrets = SecretDetector.find(in: text, loose: true, ignoring: it.notSecret)
        it.sensitive = !secrets.isEmpty
        it.ctype = secrets.isEmpty ? Classifier.classify(text) : (SecretDetector.isWholeSecret(text) ? .secret : .credential)
        store.save(it)
        if let f = e.folderId { expandedFolders.insert(f) }
        editor = nil
        selection = it.id
        rebuild()
    }

    func markNotSecret(_ it: Item) {
        var x = it
        let vals = SecretDetector.find(in: it.text, loose: it.kind == .kept, ignoring: it.notSecret).map(\.value)
        guard !vals.isEmpty else { return }
        x.notSecret += vals
        x.sensitive = false
        if x.ctype == .secret || x.ctype == .credential { x.ctype = .text }
        store.save(x)
        rebuild()
        toast("好，这条不再按密钥处理")
    }

    /// 删文件夹：里面的内容移到未归类，不删内容
    func deleteFolder(_ id: String) {
        let name = folderName(id)
        store.removeFolder(id)
        if folderFilter == id { folderFilter = nil }
        rebuild()
        toast("已删除文件夹「\(name)」，里面的内容移到了「未归类」")
    }

    func move(_ it: Item, toFolder id: String?) {
        var x = it
        x.folderId = id
        if x.kind == .clip { x.kind = .kept; x.expiresAt = nil; x.groupId = nil }
        store.save(x)
        if let id { expandedFolders.insert(id) }
        rebuild()
    }

    func askSecretConfirm(_ id: String) {
        confirmSecret = (id, Date().addingTimeInterval(6), targetName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in
            if let c = self?.confirmSecret, c.id == id, c.until <= Date() { self?.confirmSecret = nil }
        }
    }

    // MARK: 批准

    func addApproval(_ a: Approval) {
        approvals.append(a)
        rebuild()
        let id = a.id
        DispatchQueue.main.asyncAfter(deadline: .now() + (a.kind == .tool ? 50 : 150)) { [weak self] in
            guard let self, let a = self.approvals.first(where: { $0.id == id }) else { return }
            self.resolve(a, allow: false, timedOut: true)
        }
    }

    func resolve(_ a: Approval, allow: Bool, timedOut: Bool = false) {
        guard let i = approvals.firstIndex(where: { $0.id == a.id }) else { return }
        let cur = approvals.remove(at: i)
        var ch = cur.choices
        if timedOut { ch["@timeout"] = "1" }
        cur.respond(allow && !timedOut, ch)
        rebuild()
    }

    func setChoice(_ approvalId: String, name: String, itemId: String) {
        guard let i = approvals.firstIndex(where: { $0.id == approvalId }) else { return }
        approvals[i].choices[name] = itemId
        rebuild()
    }
}

enum Fmt {
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日 EEEE" : "yyyy年M月d日"
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: d)
    }

    static func time(_ d: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(d)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else if cal.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else if s < 300 * 86400 { f.dateFormat = "M月d日" }
        else { f.dateFormat = "yyyy年M月" }
        return f.string(from: d)
    }

    static func icon(_ t: ContentType) -> String {
        switch t {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .command: return "terminal"
        case .error: return "exclamationmark.triangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        case .table: return "tablecells"
        case .credential: return "person.badge.key"
        case .secret: return "key"
        case .image: return "photo"
        case .file: return "doc"
        case .email: return "envelope"
        case .phone: return "phone"
        case .path: return "folder"
        }
    }
}
