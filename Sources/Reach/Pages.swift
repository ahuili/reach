import SwiftUI
import AppKit
import ReachCore

/// 从右边滑进来的一页：左上角返回，标题，右上角主按钮，底部一行键位提示
struct PageScaffold<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var hint: String = ""
    let back: () -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(title: String, subtitle: String? = nil, hint: String = "", back: @escaping () -> Void,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.hint = hint; self.back = back
        self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.fill))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("返回（Esc）")
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let s = subtitle, !s.isEmpty { Text(s).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(Palette.line).frame(height: 0.5)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !hint.isEmpty {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 36)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 0.5) }
            }
        }
    }
}

// MARK: 新建 / 编辑抽屉里的一条

struct EditorPage: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focus: Field?
    @State private var addingFolder = false
    enum Field { case title, body, folder }

    private func bind<T>(_ kp: WritableKeyPath<EditorState, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { model.editor?[keyPath: kp] ?? fallback }, set: { model.editor?[keyPath: kp] = $0 })
    }

    private var isNew: Bool { model.editor?.itemId == nil }
    private var text: String { model.editor?.text ?? "" }
    private var detected: [ReachCore.Field] { FieldParser.parse(text, loose: true) }

    var body: some View {
        PageScaffold(title: isNew ? "新建一条" : "编辑", hint: "⌘↩ 保存   Esc 取消   密码、Key 会自动认出并打码", back: { model.editor = nil }) {
            PrimaryButton(title: "保存", shortcut: "⌘↩") { model.saveEditor() }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                TextField("标题", text: bind(\.title, ""))
                    .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .body }

                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(verbatim: "写点什么…\n\n账号、密码照常写在一起就行，比如：\n后台 https://admin.example.com\n账号 ops@example.com\n密码 ••••••")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: bind(\.text, ""))
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .focused($focus, equals: .body)
                }
                .padding(10)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fill))

                if !detected.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("认出的内容（→ 可以单独贴）").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        FlowChips(items: detected.prefix(8).map { f in
                            (PasteOption.icon(for: f.kind), f.kind == .secret ? "\(f.displayLabel) \(SecretDetector.maskHint(f.value))" : Text.truncate(f.value, 28), f.kind == .secret)
                        })
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("放在").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            folderChip(nil, "未归类")
                            ForEach(model.store.folders.sorted { $0.order < $1.order }) { f in folderChip(f.id, f.name) }
                            if addingFolder {
                                TextField("新文件夹", text: bind(\.newFolder, ""))
                                    .textFieldStyle(.plain).font(.system(size: 11.5)).frame(width: 90)
                                    .padding(.horizontal, 10).frame(height: 22)
                                    .background(Capsule().strokeBorder(Palette.brand, lineWidth: 1))
                                    .focused($focus, equals: .folder)
                                    .onSubmit { commitFolder() }
                            } else {
                                Button { addingFolder = true; focus = .folder } label: {
                                    Label("新文件夹", systemImage: "plus").font(.system(size: 11.5))
                                        .padding(.horizontal, 10).frame(height: 22)
                                        .background(Capsule().strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                                }.buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear { focus = isNew ? .title : .body }
    }

    private func commitFolder() {
        let n = (model.editor?.newFolder ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { model.editor?.folderId = model.store.folder(named: n).id }
        model.editor?.newFolder = ""
        addingFolder = false
        focus = .body
    }

    private func folderChip(_ id: String?, _ name: String) -> some View {
        let on = model.editor?.folderId == id
        return Button { model.editor?.folderId = id } label: {
            Text(name).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.brandInk : .primary)
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(on ? Palette.brand : Palette.fill))
        }.buttonStyle(.plain)
    }
}

/// 一排会自动换行的小标签
struct FlowChips: View {
    let items: [(icon: String, text: String, secret: Bool)]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 4) {
                    Image(systemName: c.icon).font(.system(size: 9.5, weight: .semibold))
                    Text(c.text).lineLimit(1)
                }
                .font(.system(size: 11, design: c.secret ? .monospaced : .default))
                .foregroundStyle(c.secret ? Palette.warn : .secondary)
                .padding(.horizontal, 8).frame(height: 21)
                .background(Capsule().fill(c.secret ? Palette.warn.opacity(0.1) : Palette.fill))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > w, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing; row = max(row, sz.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; row = max(row, sz.height)
        }
    }
}

extension PasteOption {
    static func icon(for k: FieldKind) -> String { Paster.fieldIcon(k) }
}

// MARK: 只贴一部分（怎么贴）

struct OptionsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let title = model.selectedItem.map { model.shown($0.displayTitle, $0) } ?? ""
        let secret = model.selectedItem.map { model.fields($0).contains { $0.kind == .secret } } ?? false
        let shown = model.selectedItem.map(model.isRevealed) ?? false
        PageScaffold(title: "怎么贴", subtitle: title, hint: "↑↓ 选   ↩ 贴   ⌘C 只复制" + (secret ? (shown ? "   ⌘R 打码" : "   ⌘R 显示密钥") : "") + "   数字键直接选", back: { model.options = nil }) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array((model.options ?? []).enumerated()), id: \.element.id) { i, o in
                        let on = i == model.optionIndex
                        HStack(spacing: 10) {
                            Text(i < 9 ? "\(i + 1)" : "")
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(on ? Palette.brandInk : .secondary)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Palette.brand : Palette.fill))
                            Image(systemName: o.icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
                            Text(o.label).font(.system(size: 13, weight: on ? .medium : .regular))
                            Spacer(minLength: 8)
                            Text(o.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.fillStrong : .clear))
                        .contentShape(Rectangle())
                        .onHover { if $0 { model.optionIndex = i } }
                        .onTapGesture { model.chooseOption(i) }
                    }
                }
                .padding(8)
            }
        }
    }
}

// MARK: 放进抽屉：新的一条，或接在已有的一条后面

struct SavePage: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    private var query: Binding<String> {
        Binding(get: { model.saving?.query ?? "" }, set: { q in
            model.saving?.query = q
            // 打了字就是在找已有的那条：光标跳到第一条搜到的
            let cs = model.saveChoices
            model.saving?.index = q.isEmpty ? 0 : (cs.firstIndex { if case .append = $0 { return true }; return false } ?? 0)
        })
    }

    var body: some View {
        let s = model.saving
        let n = s?.ids.count ?? 0
        let first = s?.ids.first.flatMap { model.store.items[$0] }
        let choices = model.saveChoices
        let firstAppend = choices.firstIndex { if case .append = $0 { return true }; return false }
        PageScaffold(title: "放进抽屉", subtitle: n > 1 ? "选中的 \(n) 条" : first.map { model.shown($0.displayTitle, $0) },
                     hint: "↑↓ 选   ↩ 放进去   打字找已有的一条   Esc 返回", back: { model.saving = nil }) {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.tertiary)
                    TextField("找抽屉里已有的一条，接在它后面", text: query)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($focused)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.fill))
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                                if i == firstAppend { SectionLabel(title: "接在已有的一条后面", trailing: "\(choices.count - i)") }
                                row(i, c).id(i)
                            }
                            if firstAppend == nil {
                                Text((s?.query ?? "").isEmpty ? "抽屉里还没有能接上的文字。" : "抽屉里没有对得上的。")
                                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 14)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: s?.index ?? 0) { i in proxy.scrollTo(i) }
                }
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private func row(_ i: Int, _ c: SaveChoice) -> some View {
        let on = i == (model.saving?.index ?? 0)
        let n = model.saving?.ids.count ?? 0
        let (icon, label, detail): (String, String, String) = {
            switch c {
            case .new: return ("plus.square", n > 1 ? "合成一条新的" : "存成新的一条", "↩")
            case .each: return ("square.stack", "每条单独放一条", "\(n) 条")
            case .append(let id):
                guard let it = model.store.items[id] else { return ("doc", "", "") }
                return (Fmt.icon(it.ctype), model.shown(it.displayTitle, it), model.folderName(it.folderId))
            }
        }()
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            Text(label).font(.system(size: 13, weight: on ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.fillStrong : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { model.saving?.index = i } }
        .onTapGesture { model.finishSave(c) }
    }
}

// MARK: 填空再贴

struct TemplatePage: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focus: String?

    var body: some View {
        let t = model.template
        PageScaffold(title: "填空再贴", subtitle: t?.item.displayTitle, hint: "Tab 下一个空   ↩ 贴   Esc 返回", back: { model.template = nil }) {
            PrimaryButton(title: "贴", shortcut: "↩") { (NSApp.delegate as? AppDelegate)?.panelController.fillTemplate() }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(t?.slots ?? [], id: \.name) { s in
                        let b = Binding(get: { model.template?.values[s.name] ?? "" }, set: { model.template?.values[s.name] = $0 })
                        VStack(alignment: .leading, spacing: 5) {
                            Text(s.options.isEmpty ? s.name : "选一个").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            if s.options.isEmpty {
                                TextField(s.name, text: b)
                                    .textFieldStyle(.plain).font(.system(size: 13))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.fill))
                                    .focused($focus, equals: s.name)
                            } else {
                                Picker("", selection: b) { ForEach(s.options, id: \.self) { Text($0).tag($0) } }
                                    .pickerStyle(.segmented).labelsHidden()
                            }
                        }
                    }
                    if let t {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("会贴出").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            Text(Template.fill(t.item.text, values: t.values))
                                .font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                        }
                    }
                }
                .padding(16)
            }
        }
        .onAppear { focus = t?.slots.first { $0.options.isEmpty }?.name }
    }
}

// MARK: 管理文件夹

struct FolderManagerPage: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""
    @State private var confirmDelete: String?
    @FocusState private var newFocused: Bool

    var body: some View {
        let folders = model.store.folders.sorted { $0.order < $1.order }
        PageScaffold(title: "文件夹", subtitle: "\(folders.count) 个", hint: "改名后按 ↩ 保存。删除文件夹不会删里面的内容，它们会移到「未归类」。", back: { model.managingFolders = false }) {
            PrimaryButton(title: "完成") { model.managingFolders = false }
        } content: {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { i, f in
                        FolderEditRow(folder: f, count: model.store.kept.filter { $0.folderId == f.id }.count,
                                      first: i == 0, last: i == folders.count - 1, confirming: confirmDelete == f.id,
                                      onDelete: {
                                          if confirmDelete == f.id { model.deleteFolder(f.id); confirmDelete = nil } else { confirmDelete = f.id }
                                      })
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.brand).frame(width: 22)
                        TextField("新文件夹的名字，回车建好", text: $newName)
                            .textFieldStyle(.plain).font(.system(size: 13)).focused($newFocused)
                            .onSubmit {
                                let n = newName.trimmingCharacters(in: .whitespaces)
                                guard !n.isEmpty else { return }
                                model.store.folder(named: n); newName = ""; model.rebuild(); newFocused = true
                            }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                    .padding(.top, 6)
                }
                .padding(10)
            }
        }
        .onAppear { if folders.isEmpty { newFocused = true } }
    }
}

struct FolderEditRow: View {
    @EnvironmentObject var model: AppModel
    let folder: Folder
    let count: Int
    let first: Bool
    let last: Bool
    let confirming: Bool
    let onDelete: () -> Void
    @State private var name = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 22)
            TextField("名字", text: $name)
                .textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit { model.store.renameFolder(folder.id, to: name); model.rebuild() }
            Text("\(count) 条").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            if hover || confirming {
                HStack(spacing: 2) {
                    iconButton("chevron.up", disabled: first) { model.store.moveFolder(folder.id, by: -1); model.rebuild() }
                    iconButton("chevron.down", disabled: last) { model.store.moveFolder(folder.id, by: 1); model.rebuild() }
                }
                Button(action: onDelete) {
                    Group {
                        if confirming { Text("确认删除").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8) }
                        else { Image(systemName: "trash").font(.system(size: 11)).frame(width: 22) }
                    }
                    .frame(height: 22)
                    .foregroundStyle(confirming ? .white : Palette.warn)
                    .background(Capsule().fill(confirming ? Palette.warn : Palette.warn.opacity(0.1)))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Palette.fill : .clear))
        .onHover { hover = $0 }
        .onAppear { name = folder.name }
        .onChange(of: folder.name) { name = $0 }
    }

    private func iconButton(_ icon: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22)
                .background(Circle().fill(Palette.fill))
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(disabled).opacity(disabled ? 0.3 : 1)
    }
}
