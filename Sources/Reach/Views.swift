import SwiftUI
import AppKit
import ReachCore

// MARK: 设计规范
//
// 一种强调色：暖黄（图标里那道侧栏边）。选中、勾选、主按钮、当前标签都用它；警告用橙红。
// 圆角：面板 14，卡片 10，小块 7，标签胶囊。字号：标题 13 中粗，正文 11.5，辅助 10.5。
// 没有灰色蒙层弹窗：新建、编辑、怎么贴、填空、管理文件夹都是从右边滑进来的一页，左上角返回。

enum Palette {
    static let brand = Color(red: 0.96, green: 0.70, blue: 0.20)
    static let brandInk = Color(red: 0.42, green: 0.27, blue: 0.02)
    static let warn = Color(red: 0.87, green: 0.35, blue: 0.16)
    static let fill = Color.primary.opacity(0.05)
    static let fillStrong = Color.primary.opacity(0.08)
    static let line = Color.primary.opacity(0.08)
    static let raised = Color(nsColor: .controlBackgroundColor)

    static func tint(_ t: ContentType) -> Color {
        switch t {
        case .link: return .blue
        case .command, .code, .json: return .indigo
        case .error: return .red
        case .credential, .secret: return warn
        case .image: return .purple
        case .file, .path: return .teal
        case .email, .phone: return .green
        case .table: return .orange
        case .text: return .gray
        }
    }
}

/// App 图标缓存（复制来源）
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ bundle: String?) -> NSImage? {
        guard let b = bundle else { return nil }
        if let i = cache[b] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 64, height: 64)
        cache[b] = i
        return i
    }
}

struct PrimaryButton: View {
    let title: String
    var shortcut: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let s = shortcut { Text(s).font(.system(size: 10.5, weight: .medium)).opacity(0.6) }
            }
            .foregroundStyle(Palette.brandInk)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(Palette.brand))
        }
        .buttonStyle(.plain)
    }
}

struct QuietButton: View {
    let title: String
    var icon: String? = nil
    var role: Color = .primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let i = icon { Image(systemName: i).font(.system(size: 10.5, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(role)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Palette.fillStrong))
        }
        .buttonStyle(.plain)
    }
}

struct TagView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13))).fixedSize()
    }
}

// MARK: 侧栏

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool

    private var pageKey: Int {
        model.editor != nil ? 1 : model.options != nil ? 2 : model.template != nil ? 3 : model.managingFolders ? 4 : 0
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                banners
                list
                FooterView()
            }
            .opacity(pageKey == 0 ? 1 : 0)
            Group {
                switch pageKey {
                case 1: EditorPage()
                case 2: OptionsPage()
                case 3: TemplatePage()
                case 4: FolderManagerPage()
                default: EmptyView()
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .animation(.easeOut(duration: 0.18), value: pageKey)
        .onChange(of: model.focusTick) { _ in searchFocused = true }
        .onChange(of: pageKey) { k in if k == 0 { searchFocused = true } }
        .onAppear { searchFocused = true }
    }

    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                TextField("搜索", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                if let b = model.busy { ProgressView().controlSize(.mini); Text(b).font(.system(size: 11)).foregroundStyle(.secondary) }
                if searching {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                } else if !model.targetName.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.turn.down.left").font(.system(size: 9, weight: .semibold))
                        Text(model.targetName).lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                    .help("回车贴到这个窗口")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fill))

            if !searching {
                SegmentedTabs()
                if model.tab == .kept { FolderChips() }
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
    }

    @ViewBuilder private var banners: some View {
        if let c = model.confirmSecret {
            Banner(icon: "exclamationmark.shield.fill", color: Palette.warn,
                   text: "这是密钥，要贴进「\(c.app)」吗？再按一次回车确认，Esc 取消。")
        }
        if let n = model.sideNotesHint, n > 0, model.query.isEmpty {
            Banner(icon: "tray.and.arrow.down.fill", color: Palette.brand, text: "SideNotes 里有 \(n) 条笔记，要搬过来吗？") {
                PrimaryButton(title: "搬过来") { model.importSideNotes() }
                Button { model.sideNotesHint = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.rows) { row in RowView(row: row).id(row.id) }
                }
                .padding(.horizontal, 8).padding(.bottom, 10)
            }
            .onChange(of: model.selection) { sel in
                if let sel { withAnimation(.linear(duration: 0.08)) { proxy.scrollTo("i:" + sel, anchor: nil) } }
            }
            .onChange(of: model.tab) { _ in if let f = model.rows.first { proxy.scrollTo(f.id, anchor: .top) } }
        }
    }
}

struct Banner<Trailing: View>: View {
    let icon: String
    let color: Color
    let text: String
    @ViewBuilder var trailing: Trailing
    init(icon: String, color: Color, text: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.color = color; self.text = text; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.12)))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

/// 最近复制 / 留存：一条滑块式分段
struct SegmentedTabs: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 0) {
            seg(.recent, "最近复制", model.store.clips.count)
            seg(.kept, "留存", model.store.kept.count)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.fill))
    }

    private func seg(_ t: Tab, _ title: String, _ n: Int) -> some View {
        let on = model.tab == t
        return Button { withAnimation(.easeOut(duration: 0.15)) { model.tab = t } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                Text("\(n)").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.raised)
                        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "seg", in: ns)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? .primary : .secondary)
        .help("\(title)（\(t == .recent ? "⌘1" : "⌘2")，或按 Tab 切换）")
    }
}

/// 留存页顶上一排文件夹：点一下筛选，右键改名删除，卡片可以拖上来
struct FolderChips: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(model.folderChips, id: \.name) { c in chip(c) }
                Button { model.managingFolders = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(Palette.fill))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("新建、改名、删除、排序文件夹")
            }
        }
    }

    private func chip(_ c: (id: String?, name: String, count: Int)) -> some View {
        let on = model.folderFilter == c.id
        return Button { model.folderFilter = c.id } label: {
            HStack(spacing: 4) {
                if c.id == "@common" { Image(systemName: "star.fill").font(.system(size: 8.5)).foregroundStyle(on ? Palette.brandInk : Palette.brand) }
                Text(c.name).lineLimit(1)
                Text("\(c.count)").monospacedDigit().opacity(0.55)
            }
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Palette.brandInk : .primary)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(on ? Palette.brand : Palette.fill))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let id = c.id, !id.hasPrefix("@") {
                Button("改名、排序、删除…") { model.managingFolders = true }
                Button("删除「\(c.name)」（里面的留存移到未归类）") { model.deleteFolder(id) }
            }
            Button("新建文件夹…") { model.managingFolders = true }
        }
        .onDrop(of: ["public.plain-text"], isTargeted: nil) { providers in
            guard let id = c.id, id != "@common" else { return false }
            return loadDrop(providers) { itemId in
                for x in model.dropIds(itemId) { if let it = model.store.items[x] { model.move(it, toFolder: id == "@loose" ? nil : id) } }
            }
        }
    }
}

struct RowView: View {
    @EnvironmentObject var model: AppModel
    let row: Row

    var body: some View {
        switch row {
        case .header(let title, let sub):
            SectionLabel(title: title, trailing: sub)
        case .day(let t):
            SectionLabel(title: t)
        case .approval(let a): ApprovalCard(approval: a).padding(.vertical, 4)
        case .agent(let s): AgentCard(session: s).padding(.vertical, 2)
        case .group(let id, let title, let subtitle, let count, let expanded):
            Button { model.toggleGroup(id, expanded: expanded) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.fillStrong)
                        Text("\(count)").font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    }.frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
        case .folder(let id, let name, let count, let expanded):
            Button { model.toggleFolder(id, expanded: expanded) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(name).font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 0)
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            }.buttonStyle(.plain)
        case .item(let it, let indent):
            ItemRow(item: it)
                .padding(.leading, indent ? 16 : 0)
                .overlay(alignment: .leading) {
                    if indent { RoundedRectangle(cornerRadius: 1).fill(Palette.line).frame(width: 2).padding(.leading, 21).padding(.vertical, 4) }
                }
        case .note(let t):
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                Text(t).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
        }
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(trailing).font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.top, 12).padding(.bottom, 3).padding(.horizontal, 8)
    }
}

func loadDrop(_ providers: [NSItemProvider], _ use: @escaping (String) -> Void) -> Bool {
    guard let p = providers.first else { return false }
    _ = p.loadObject(ofClass: NSString.self) { obj, _ in
        guard let s = obj as? String, s.hasPrefix("reach-item:") else { return }
        DispatchQueue.main.async { use(String(s.dropFirst("reach-item:".count))) }
    }
    return true
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: Item
    @State private var hover = false

    private var selected: Bool { model.selection == item.id }
    private var inBasket: Bool { model.basket.contains(item.id) }
    private var picking: Bool { !model.basket.isEmpty }
    private var isSecret: Bool { item.sensitive || item.ctype == .secret || item.ctype == .credential }

    private var preview: String? {
        if item.ctype == .image || item.ctype == .file { return nil }
        let body = Markdown.looksMarkdown(item.text) ? Markdown.toPlain(item.text) : item.text
        let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let rest = item.title.isEmpty ? Array(lines.dropFirst()) : lines
        guard !rest.isEmpty else { return nil }
        return model.shown(rest.prefix(2).joined(separator: "\n"), item)
    }

    private var meta: String {
        var parts: [String] = []
        if item.kind == .kept, model.folderFilter == nil || !model.query.isEmpty {
            let f = model.folderName(item.folderId); if !f.isEmpty { parts.append(f) }
        }
        if item.kind == .visit {
            let to = item.openedIn.flatMap(LinkTarget.init(key:)).map { model.links?.dest($0)?.title ?? LinkBrowsers.name($0.browser) }
            parts.append([item.sourceApp, to].compactMap { $0 }.joined(separator: " → "))
            parts.append(Fmt.time(item.createdAt))
            return parts.joined(separator: " · ")
        }
        if let a = item.sourceApp, item.origin != .imported { parts.append(item.origin == .agent ? "来自 \(a)" : a) }
        parts.append(Fmt.time(item.kind == .kept ? (item.lastUsedAt ?? item.createdAt) : item.createdAt))
        if let t = model.targetBundle, let n = item.useByApp[t], n > 0 { parts.append("在\(model.targetName)贴过 \(n) 次") }
        else if item.useCount > 0 { parts.append("贴过 \(item.useCount) 次") }
        return parts.joined(separator: " · ")
    }

    private var hint: String {
        let fs = model.fields(item)
        var s = "↩ 贴  → 只贴一部分"
        if fs.contains(where: { $0.kind == .account }) && fs.contains(where: { $0.kind == .secret }) { s += "  ⌥↩ 填登录" }
        if item.kind == .clip { s += "  ⌘S 留存" } else { s += "  ⌘E 编辑" }
        return s
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.shown(item.displayTitle, item)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    tag
                }
                if item.ctype == .image, let f = item.imageFile { Thumb(file: f).padding(.vertical, 3) }
                if let p = preview {
                    Text(p).font(.system(size: 11.5, design: [.command, .code, .json, .error, .path].contains(item.ctype) ? .monospaced : .default))
                        .foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(selected && !picking ? hint : meta).font(.system(size: 10.5)).foregroundStyle(selected && !picking ? .secondary : .tertiary).lineLimit(1)
            }
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(
            inBasket ? Palette.brand.opacity(0.14) : (selected ? Palette.fillStrong : (hover ? Palette.fill : .clear))))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(Palette.brand).frame(width: 3).padding(.vertical, 10).offset(x: -1) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.selection = item.id; model.activate(item) }
        .onTapGesture {
            let f = NSEvent.modifierFlags
            if f.contains(.shift) { model.basketRange(to: item) }
            else if f.contains(.command) || picking { model.toggleBasket(item) }
            model.selection = item.id
        }
        .onDrag { NSItemProvider(object: ("reach-item:" + item.id) as NSString) }
        .contextMenu { menu }
    }

    /// 左边：复制来源的 App 图标，或内容类型的小色块；鼠标移上来、正在多选时变成勾选框
    @ViewBuilder private var leading: some View {
        let showCheck = hover || picking
        ZStack {
            if showCheck {
                Circle().fill(inBasket ? Palette.brand : Color.clear)
                Circle().strokeBorder(inBasket ? Palette.brand : Color.secondary.opacity(0.45), lineWidth: 1.5)
                if inBasket { Image(systemName: "checkmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.brandInk) }
            } else if item.kind == .visit, let icon = item.openedIn.flatMap(LinkTarget.init(key:)).flatMap({ LinkBrowsers.icon($0.browser) }) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26)
            } else if item.kind == .clip, item.ctype != .credential, item.ctype != .secret, let icon = AppIcons.icon(item.sourceBundle) {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 26, height: 26)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.tint(item.ctype).opacity(0.14))
                Image(systemName: Fmt.icon(item.ctype)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Palette.tint(item.ctype))
            }
        }
        .frame(width: showCheck ? 20 : 28, height: showCheck ? 20 : 28)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.shift) { model.basketRange(to: item) } else { model.toggleBasket(item) }
        }
        .help(inBasket ? "取消选择" : "选中（几条合成一段贴）")
    }

    @ViewBuilder private var tag: some View {
        if isSecret {
            if item.kind == .clip, let e = item.expiresAt {
                let m = max(1, Int(e.timeIntervalSinceNow / 60))
                TagView(text: m < 90 ? "\(m) 分钟后清除" : (m < 2880 ? "\(m / 60) 小时后清除" : "含密钥"), color: Palette.warn)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(Palette.warn.opacity(0.8)).help("含密钥，已打码（⌘R 显示）")
            }
        } else if item.origin == .agent {
            TagView(text: "Agent 产出", color: Palette.brand)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("贴") { model.selection = item.id; model.activate(item) }
        Button("只贴一部分…") { model.selection = item.id; model.openOptions() }
        if item.kind == .clip { Button("留存") { model.keep(item) } }
        Button("编辑") { model.edit(item) }
        Button(model.basket.contains(item.id) ? "取消选择" : "选中") { model.toggleBasket(item) }
        if !model.store.folders.isEmpty {
            Menu("移到") {
                ForEach(model.store.folders.sorted { $0.order < $1.order }) { f in Button(f.name) { model.move(item, toFolder: f.id) } }
            }
        }
        if model.settings.agentRail, !model.agents.isEmpty {
            Menu("发给 Agent") {
                ForEach(model.agents) { s in Button("\(s.agent.name) · \(s.project)") { model.rail.send(items: [item.id], to: s) } }
            }
        }
        if isSecret {
            Button(model.isRevealed(item) ? "重新打码" : "显示密钥") {
                if model.revealed.contains(item.id) { model.revealed.remove(item.id) } else { model.revealed.insert(item.id) }
            }
            Button("这不是密钥") { model.markNotSecret(item) }
        }
        Divider()
        Button(model.basket.count > 1 && inBasket ? "删除选中的 \(model.basket.count) 条" : "删除") {
            if model.basket.count > 1 && inBasket {
                for id in model.basket { if let x = model.store.items[id] { model.remove(x) } }
                model.basket = []
            } else { model.remove(item) }
        }
    }
}

struct Thumb: View {
    @EnvironmentObject var model: AppModel
    let file: String
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 110, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Palette.line))
            } else { RoundedRectangle(cornerRadius: 6).fill(Palette.fill).frame(height: 50) }
        }
        .onAppear {
            guard image == nil else { return }
            let store = model.store
            DispatchQueue.global(qos: .userInitiated).async {
                let img = store.loadImage(file).flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { image = img }
            }
        }
    }
}

struct FooterView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            if !model.basket.isEmpty {
                ZStack {
                    Circle().fill(Palette.brand)
                    Text("\(model.basket.count)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Palette.brandInk).monospacedDigit()
                }.frame(width: 20, height: 20)
                Text("已选 \(model.basket.count) 条").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                QuietButton(title: "清空") { model.basket = [] }
                PrimaryButton(title: "合成一段贴", shortcut: "⌘↩") { model.paster.pasteBasket() }
            } else {
                Text("↩ 贴   → 只贴一部分   空格 多选   Tab 切换").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                if model.settings.paused { TagView(text: "已暂停记录", color: Palette.warn) }
                Button { model.hidePanel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.shot.start() } } label: { Image(systemName: "viewfinder").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("截图（\(model.settings.shotKey.label)）")
                Button { model.newNote() } label: { Image(systemName: "square.and.pencil").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("新建留存（⌘N）")
                Button { (NSApp.delegate as? AppDelegate)?.openSettings() } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("设置（⌘,）")
            }
        }
        .padding(.horizontal, 14).frame(height: 42)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 0.5) }
    }
}

// MARK: Agent 和批准

struct ApprovalCard: View {
    @EnvironmentObject var model: AppModel
    let approval: Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Palette.brand.opacity(0.2))
                    Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(Palette.brandInk)
                }.frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(approval.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text("\(approval.agent) 在请求").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(approval.lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !approval.matches.isEmpty {
                VStack(spacing: 6) {
                    ForEach(approval.matches, id: \.name) { m in EnvRow(approvalId: approval.id, match: m, chosen: approval.choices[m.name]) }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
            }
            if let w = approval.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Palette.warn)
            }
            HStack(spacing: 6) {
                Spacer()
                QuietButton(title: "拒绝") { model.resolve(approval, allow: false) }
                PrimaryButton(title: approval.kind == .tool ? "允许" : "允许一次") { model.resolve(approval, allow: true) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.brand, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

struct EnvRow: View {
    @EnvironmentObject var model: AppModel
    let approvalId: String
    let match: EnvMatch
    let chosen: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(match.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 4)
            if match.candidates.isEmpty {
                Text("没找到").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else if match.candidates.count == 1, let c = match.candidates.first {
                Text("\(c.title) \(c.masked)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Picker("", selection: Binding(get: { chosen ?? "" }, set: { model.setChoice(approvalId, name: match.name, itemId: $0) })) {
                    Text("选一个…").tag("")
                    ForEach(match.candidates, id: \.itemId) { c in
                        Text("\(c.folder.isEmpty ? "" : c.folder + " › ")\(c.title) \(c.masked)").tag(c.itemId)
                    }
                }.labelsHidden().controlSize(.small).frame(maxWidth: 210)
            }
        }
    }
}

struct AgentCard: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    @State private var reply = ""
    @State private var targeted = false
    @FocusState private var replyFocused: Bool

    private var dot: Color {
        switch session.state {
        case .running: return .blue
        case .waiting: return Palette.warn
        case .maybeWaiting: return Palette.brand
        case .done: return .green
        case .idle: return .gray
        }
    }

    private var status: String {
        switch session.state {
        case .running: return "在干活"
        case .waiting: return "等你"
        case .maybeWaiting: return "可能在等你"
        case .done: return "完成"
        case .idle: return "停着"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text("\(session.agent.name) · \(session.project.isEmpty ? "未知项目" : session.project)").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                TagView(text: status, color: dot)
                Button { model.dismissedAgents.insert(model.agentKey(session)); model.rebuild() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("先收起，有新动静再出来")
            }
            if !session.title.isEmpty { Text(session.title).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            let body = session.state == .done ? Markdown.toPlain(session.lastMessage) : session.detail
            if !body.isEmpty {
                Text(body).font(.system(size: 11.5)).foregroundStyle(session.state == .done ? .primary : .secondary)
                    .lineLimit(session.state == .done ? 4 : 2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                TextField(targeted ? "松手发给它" : "回一句…", text: $reply)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($replyFocused)
                    .onSubmit { let t = reply; reply = ""; replyFocused = false; model.replyingTo = nil; if !t.isEmpty { model.rail.send(text: t, to: session) } }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(Palette.fill))
                if session.state == .done, !session.lastMessage.isEmpty {
                    QuietButton(title: "复制结论") { Pasteboard.write(Payload(plain: session.lastMessage)); model.paster.monitor?.syncCount(); model.toast("已复制") }
                }
                QuietButton(title: "去窗口") { model.rail.jump(to: session) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(session.state == .waiting ? Palette.warn : (targeted ? Palette.brand : .clear), lineWidth: 1.5))
        .onChange(of: replyFocused) { f in model.replyingTo = f ? session.id : (model.replyingTo == session.id ? nil : model.replyingTo) }
        .onDrop(of: ["public.plain-text"], isTargeted: $targeted) { providers in
            loadDrop(providers) { id in model.rail.send(items: [id], to: session) }
        }
    }
}
