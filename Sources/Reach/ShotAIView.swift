import AppKit
import Combine
import SwiftUI
import ReachCore

/// 截图里的两件 AI 小事：
/// - 原位翻译（Y）：认出的每一行字，用原来的底色盖上译文，复制出去的图也是译好的
/// - 看懂（K）：选区旁边一张卡片，按内容说清这是什么——外文给译文和难词、报错给原因和下一步、图表给结论；能接着问
final class ShotExplain: ObservableObject {
    struct Turn: Identifiable { let id = UUID(); var question: String?; var answer: String }
    @Published var turns: [Turn] = []
    @Published var busy = true
    @Published var error: String?
    @Published var input = ""
    @Published var bodyHeight: CGFloat = 60
    var messages: [[String: Any]] = []
    var sentImage = false
}

extension ShotController {
    private var aiCfg: AISettings { model.store.settings.ai }

    private func say(_ s: ShotSession, _ text: String) {
        s.notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak s] in if s?.notice == text { s?.notice = nil } }
    }

    private var notReadyText: String { Magpie.installed ? "先在 设置 › AI 里选个模型（可以直接选本机 Magpie 里的）" : "先在 设置 › AI 里选个模型" }

    // MARK: 原位翻译

    func toggleTranslate() {
        guard let s = session, let d = doc else { return }
        switch s.trans {
        case .on: d.glosses = []; s.trans = .off; return
        case .loading: return
        case .off: break
        }
        if s.reading { s.pending = .translate; return }
        if let c = s.glossCache { d.glosses = c; s.trans = .on; return }
        guard aiCfg.isReady else { say(s, notReadyText); return }
        let target = ShotAI.translateTarget(s.lines)
        // 带密钥的行不发出去，也不盖
        let idx = s.lines.indices.filter { i in
            !(s.lineSecret.indices.contains(i) && s.lineSecret[i]) && s.lineBoxes.indices.contains(i) && ShotAI.worthTranslating(s.lines[i], to: target)
        }
        guard !idx.isEmpty else { say(s, target == "English" ? "图里没认出要翻译的字" : "图里没认出外文"); return }
        s.trans = .loading
        let src = idx.map { s.lines[$0] }
        let cfg = aiCfg
        Task { @MainActor in
            let json = String(data: (try? JSONSerialization.data(withJSONObject: src)) ?? Data(), encoding: .utf8) ?? "[]"
            var out: [String]?
            var failure: Error?
            for _ in 0..<2 where out == nil {
                do {
                    let ans = try await AIClient(cfg).complete(system: ShotAI.translateSystem(target: target), user: json, maxTokens: 3000, timeout: 60)
                    out = ShotAI.parseLines(ans, count: src.count)
                } catch { failure = error; break }
            }
            guard self.doc === d else { return }
            guard let out else {
                s.trans = .off
                self.say(s, failure.map { "翻译没成：\($0)" } ?? "翻译没成：模型给回的行数对不上")
                return
            }
            var g: [ShotGloss] = []
            for (k, i) in idx.enumerated() {
                let t = out[k].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != s.lines[i] else { continue }
                let c = ShotRender.colors(of: d.image, at: s.lineBoxes[i])
                g.append(ShotGloss(rect: s.lineBoxes[i], text: t, bg: c.bg, fg: c.fg))
            }
            s.glossCache = g
            d.glosses = g
            s.trans = .on
        }
    }

    // MARK: 看懂

    func toggleExplain() {
        guard let s = session, let d = doc, let v = editingView else { return }
        if s.explain != nil {
            s.explain = nil
            card?.removeFromSuperview(); card = nil
            v.window?.makeFirstResponder(canvas)
            return
        }
        if s.reading { s.pending = .explain; return }
        guard aiCfg.isReady else { say(s, notReadyText); return }
        let cfg = aiCfg
        // 图只在：模型能看图，并且图里没认出密钥、或者认出的都打上了码
        let sendImage = cfg.vision && (s.secrets == 0 || d.autoCount > 0)
        if s.lines.isEmpty, !sendImage {
            say(s, cfg.vision ? "图里有没遮住的密钥，没发给模型" : "图里没认出字。在设置里换一个能看图的模型，就能直接看图回答")
            return
        }
        let e = ShotExplain()
        var content: [[String: Any]] = [["type": "text", "text": ShotAI.explainUser(lines: s.lines, app: source?.name)]]
        if sendImage, let url = Self.dataURL(ShotRender.render(d.image, d.marks)) {
            content.append(["type": "image_url", "image_url": ["url": url]])
            e.sentImage = true
        }
        e.messages = [["role": "system", "content": ShotAI.explainSystem], ["role": "user", "content": e.sentImage ? content : content[0]["text"]!]]
        s.explain = e
        let h = NSHostingView(rootView: ShotExplainCard(e: e, act: { [weak self] a in self?.act(a) }))
        v.addSubview(h)
        card = h
        cardWatch = e.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.placeCard() } }
        placeCard()
        run(e, cfg: cfg, question: nil)
    }

    func ask(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = session?.explain, !q.isEmpty, !e.busy else { return }
        e.input = ""
        e.messages.append(["role": "user", "content": SecretDetector.redact(q)])
        e.busy = true; e.error = nil
        run(e, cfg: aiCfg, question: q)
    }

    private func run(_ e: ShotExplain, cfg: AISettings, question: String?) {
        Task { @MainActor in
            do {
                let ans = try await AIClient(cfg).chat(e.messages, maxTokens: 1500, temperature: 0.3, timeout: 90)
                e.messages.append(["role": "assistant", "content": ans])
                e.turns.append(.init(question: question, answer: ans))
            } catch {
                // 问失败了：这一问从对话里拿掉，免得下一问带着
                if question != nil, e.messages.last?["role"] as? String == "user" { e.messages.removeLast() }
                e.error = e.sentImage && e.turns.isEmpty ? "没问成：\(error)。如果这个模型不能看图，到设置里关掉「模型能看图」。" : "没问成：\(error)"
            }
            e.busy = false
        }
    }

    private var answerText: String {
        (session?.explain?.turns ?? []).map { t in (t.question.map { "问：\($0)\n\n" } ?? "") + t.answer }.joined(separator: "\n\n")
    }

    func copyAnswer() {
        guard let s = session, !answerText.isEmpty else { return }
        if !testMode {
            Pasteboard.write(Payload(plain: Markdown.toPlain(answerText)))
            monitor.syncCount()
        }
        say(s, "已复制回答")
    }

    /// 回答连同图里的字（密钥换圆点）一起放进抽屉
    func keepAnswer() {
        guard let s = session, !answerText.isEmpty else { return }
        var text = answerText
        let orig = SecretDetector.mask(s.lines.joined(separator: "\n"))
        if !orig.isEmpty { text += "\n\n—— 截图里的字 ——\n" + orig }
        var it = Item(kind: .kept, text: text, sourceApp: source?.name, origin: .manual, hash: store.vault.fingerprint(Data(text.utf8)))
        it.title = "看懂：" + (Text.firstLine(Markdown.toPlain(s.explain?.turns.first?.answer ?? ""), max: 24) ?? "截图")
        it.sensitive = !SecretDetector.find(in: text, loose: true).isEmpty
        it.ctype = it.sensitive ? .credential : Classifier.classify(text)
        store.save(it)
        model.rebuild()
        model.organizer.autoFile(it.id)
        say(s, "已放进抽屉")
    }

    /// 卡片放在选区右边；放不下放左边；都放不下压在选区里靠右
    func placeCard() {
        guard let h = card, let v = editingView, let e = session?.explain else { return }
        let w: CGFloat = 380
        let cap = min(460, v.bounds.height * 0.62)
        let measured = NSHostingView(rootView: ShotExplainBody(e: e).frame(width: w - 28)).fittingSize.height
        let bodyH = min(cap, max(40, measured))
        if abs(bodyH - e.bodyHeight) > 1 { e.bodyHeight = bodyH; return } // 改了高度会再触发一次
        let sz = CGSize(width: w, height: h.fittingSize.height)
        let sel = v.selection ?? .zero
        var x: CGFloat
        if sel.maxX + 12 + w <= v.bounds.width - 8 { x = sel.maxX + 12 }
        else if sel.minX - 12 - w >= 8 { x = sel.minX - 12 - w }
        else { x = min(sel.maxX, v.bounds.width - 8) - w - 8 }
        x = max(8, x)
        let y = max(8, min(v.bounds.height - sz.height - 8, sel.minY))
        h.frame = CGRect(x: x, y: y, width: sz.width, height: sz.height)
    }

    /// 发给模型的图：长边不超过 1600，JPEG
    static func dataURL(_ img: CGImage) -> String? {
        let longest = CGFloat(max(img.width, img.height))
        let s = min(1, 1600 / longest)
        var src = img
        if s < 1, let c = CGContext(data: nil, width: Int(CGFloat(img.width) * s), height: Int(CGFloat(img.height) * s), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.interpolationQuality = .high
            c.draw(img, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
            if let r = c.makeImage() { src = r }
        }
        guard let d = NSBitmapImageRep(cgImage: src).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }
}

// MARK: 卡片

private let ink = Color(red: 0.25, green: 0.16, blue: 0.0)
private let amber = Color(red: 0.96, green: 0.70, blue: 0.20)

struct ShotExplainBody: View {
    @ObservedObject var e: ShotExplain

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(e.turns) { t in
                if let q = t.question {
                    Text(q).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                ForEach(Array(ShotAI.segments(t.answer).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let s):
                        Text(Self.rich(s)).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.92)).lineSpacing(3)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    case .code(let c): CodeBlock(code: c)
                    }
                }
            }
            if e.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).colorScheme(.dark)
                    Text(e.turns.isEmpty ? (e.sentImage ? "在看图…" : "在读图里的字…") : "想一下…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                }
            }
            if let err = e.error {
                Text(err).font(.system(size: 11.5)).foregroundStyle(amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 只认行内的 **粗体** 和 `代码`，换行原样保留
    static func rich(_ s: String) -> AttributedString {
        let cleaned = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            while l.hasPrefix("#") { l.removeFirst() }
            return l.hasPrefix(" ") && line.hasPrefix("#") ? String(l.dropFirst()) : l
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cleaned)
    }
}

private struct CodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(code).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Button {
                Pasteboard.write(Payload(plain: code)); copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }.buttonStyle(.plain).help("复制这段")
        }
        .padding(8)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct ShotExplainCard: View {
    @ObservedObject var e: ShotExplain
    let act: (ShotController.Action) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(amber)
                Text("看懂").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                if e.sentImage { Text("· 看了图").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)) }
                Spacer(minLength: 0)
                Button { act(.explain) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).help("收起  K 或 Esc")
            }
            ScrollView { ShotExplainBody(e: e).padding(.trailing, 4) }
                .frame(height: e.bodyHeight)
            HStack(spacing: 6) {
                TextField("", text: $e.input, prompt: Text("接着问，比如「第二句什么意思」").foregroundColor(.white.opacity(0.35)))
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { act(.ask(e.input)) }
                    .onExitCommand { act(.explain) }
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(Color.white.opacity(0.1), in: Capsule())
                    .disabled(e.busy)
                button("doc.on.doc", "复制回答") { act(.copyAnswer) }
                button("tray.and.arrow.down", "放进抽屉：回答连同图里的字存一条") { act(.keepAnswer) }
            }
            .opacity(e.turns.isEmpty ? 0.5 : 1)
            .allowsHitTesting(!e.turns.isEmpty)
        }
        .padding(14)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.12).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        )
    }

    private func button(_ icon: String, _ help: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 26, height: 26).background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(help)
    }
}
