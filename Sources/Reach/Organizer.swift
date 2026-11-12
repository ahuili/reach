import AppKit
import Vision
import NaturalLanguage
import ReachCore

/// 自动整理：截图认字、给一组复制起名、留存时自动归文件夹、按意思搜。原则是自动做、可撤销、不发问。
final class Organizer {
    let model: AppModel
    var store: Store { model.store }
    private var naming: Set<String> = []
    private var nameTimer: Timer?
    private var vectors: [String: [Double]] = [:]
    private let embed = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) ?? NLEmbedding.sentenceEmbedding(for: .english)
    private let queue = DispatchQueue(label: "reach.organizer", qos: .utility)
    private var searchSeq = 0

    init(model: AppModel) { self.model = model }

    // MARK: 截图认字

    func ocr(_ item: Item) {
        guard item.ctype == .image, item.ocr == nil, let f = item.imageFile else { return }
        let store = self.store
        queue.async {
            guard let d = store.loadImage(f), let img = NSImage(data: d), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.recognitionLanguages = ["zh-Hans", "en-US"]
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                guard var it = store.items[item.id] else { return }
                it.ocr = text
                store.save(it)
                self.model.rebuild()
            }
        }
    }

    // MARK: 给一组复制起名

    /// 每次有新复制都调一下：停下来一分钟后，给够三条的那组起个名字
    func scheduleNaming() {
        guard store.settings.ai.isReady else { return }
        nameTimer?.invalidate()
        nameTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in self?.nameLatestGroup() }
    }

    private func nameLatestGroup() {
        guard let first = store.clips.first(where: { $0.origin != .agent }), let g = first.groupId, store.groupNames[g] == nil, !naming.contains(g) else { return }
        let its = store.clips.filter { $0.groupId == g }
        guard its.count >= 3 else { return }
        naming.insert(g)
        let list = its.prefix(12).map { it -> String in
            let body = it.ctype == .image ? "（截图）" + (it.ocr ?? "") : it.text
            return "- [\(it.ctype.label)·\(it.sourceApp ?? "")] " + Text.truncate(SecretDetector.redact(body).replacingOccurrences(of: "\n", with: " "), 160)
        }.joined(separator: "\n")
        let cfg = store.settings.ai
        Task { @MainActor in
            defer { self.naming.remove(g) }
            let sys = "下面是用户在一小段时间里连续复制的几样东西。用不超过 10 个字说出他在做的这件事，例如「report-api 部署」「客户报价沟通」。只输出这几个字，不要标点和解释。"
            guard let name = try? await AIClient(cfg).complete(system: sys, user: list, maxTokens: 30) else { return }
            let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'。. \n"))
            guard !clean.isEmpty, clean.count <= 16 else { return }
            self.store.setGroupName(g, clean)
            self.model.rebuild()
        }
    }

    // MARK: 留存时自动归文件夹

    func autoFile(_ id: String) {
        guard store.settings.ai.isReady, let it = store.items[id], it.folderId == nil, !store.folders.isEmpty else { return }
        let names = store.folders.map(\.name)
        let cfg = store.settings.ai
        let body = Text.truncate(SecretDetector.redact(it.ctype == .image ? (it.ocr ?? "") : it.text), 500)
        Task { @MainActor in
            let sys = "把这条内容归到下面某一个文件夹里。只输出文件夹的名字；都不合适就输出「无」。\n文件夹：" + names.joined(separator: "、")
            guard let ans = try? await AIClient(cfg).complete(system: sys, user: body, maxTokens: 30) else { return }
            let pick = ans.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'。. \n"))
            guard let f = self.store.folders.first(where: { $0.name == pick }), var cur = self.store.items[id], cur.folderId == nil else { return }
            cur.folderId = f.id
            self.store.save(cur)
            self.model.expandedFolders.insert(f.id)
            self.model.rebuild()
            self.model.toast("已归到「\(f.name)」。放错了可以拖到别的文件夹。")
        }
    }

    // MARK: 按意思搜（本机，不联网）

    private func vector(_ it: Item) -> [Double]? {
        if let v = vectors[it.id] { return v }
        guard let embed else { return nil }
        let text = Text.truncate((it.title + " " + (it.ctype == .image ? (it.ocr ?? "") : SecretDetector.redact(it.text))).replacingOccurrences(of: "\n", with: " "), 300)
        guard let v = embed.vector(for: text) else { return nil }
        vectors[it.id] = v
        return v
    }

    func semanticSearch(_ query: String) {
        searchSeq += 1
        let seq = searchSeq
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let embed else { if !model.semantic.isEmpty { model.semantic = []; model.rebuild() }; return }
        let items = Array(store.items.values)
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, seq == self.searchSeq, let qv = embed.vector(for: q) else { return }
            var scored: [(String, Double)] = []
            for it in items {
                guard let v = self.vector(it) else { continue }
                var dot = 0.0, a = 0.0, b = 0.0
                for i in 0..<min(v.count, qv.count) { dot += v[i] * qv[i]; a += v[i] * v[i]; b += qv[i] * qv[i] }
                let sim = dot / (sqrt(a) * sqrt(b) + 1e-9)
                if sim > 0.55 { scored.append((it.id, sim)) }
            }
            let top = scored.sorted { $0.1 > $1.1 }.prefix(8).map(\.0)
            DispatchQueue.main.async {
                guard seq == self.searchSeq, top != self.model.semantic else { return }
                self.model.semantic = top
                self.model.rebuild()
            }
        }
    }
}
