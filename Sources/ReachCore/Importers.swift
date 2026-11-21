import Foundation
import SQLite3

/// 从 SideNotes 搬家：只读打开它的本地库，按原文件夹放进抽屉。
public enum SideNotesImporter {
    public static var candidates: [URL] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [base.appendingPathComponent("SideNotes/SideNotes.sqlite")]
    }

    public static var available: URL? { candidates.first { FileManager.default.fileExists(atPath: $0.path) } }

    /// SideNotes 里有多少条笔记（不含示例）
    public static func count(_ url: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        let sql = "SELECT count(*) FROM ZNOTE n JOIN ZFOLDER f ON n.ZFOLDER=f.Z_PK WHERE COALESCE(n.ZISHIDDENDELETED,0)=0 AND COALESCE(f.ZISHIDDENDELETED,0)=0 AND f.ZNAME<>'Showcase'"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(st, 0))
    }

    public struct Result { public var folders = 0; public var notes = 0; public var withSecrets = 0; public var skipped = 0 }

    @discardableResult
    public static func importInto(_ store: Store, from url: URL) -> Result {
        var res = Result()
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return res }
        defer { sqlite3_close(db) }

        var folderByPK: [Int64: (name: String, index: Int)] = [:]
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT Z_PK, ZNAME, ZINDEX FROM ZFOLDER WHERE COALESCE(ZISHIDDENDELETED,0)=0", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                let name = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? "未命名"
                folderByPK[sqlite3_column_int64(st, 0)] = (name, Int(sqlite3_column_int(st, 2)))
            }
        }
        sqlite3_finalize(st); st = nil

        var folderIds: [Int64: String] = [:]
        for (pk, f) in folderByPK.sorted(by: { $0.value.index < $1.value.index }) where f.name != "Showcase" {
            let existed = store.folders.contains { $0.name == f.name }
            folderIds[pk] = store.folder(named: f.name).id
            if !existed { res.folders += 1 }
        }

        let sql = "SELECT ZTEXT, ZFOLDER, ZDATE, ZID FROM ZNOTE WHERE COALESCE(ZISHIDDENDELETED,0)=0 ORDER BY ZINDEX"
        if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW {
                guard let tp = sqlite3_column_text(st, 0) else { continue }
                let text = String(cString: tp)
                let fpk = sqlite3_column_int64(st, 1)
                guard let fid = folderIds[fpk], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { res.skipped += 1; continue }
                let hash = store.vault.fingerprint(Data(text.utf8))
                if store.find(hash: hash, kind: .kept) != nil { res.skipped += 1; continue } // 重复导入不会多出一份
                // Core Data 的时间从 2001-01-01 算起
                let date = sqlite3_column_type(st, 2) == SQLITE_NULL ? Date() : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 2))
                var it = Item(kind: .kept, text: text, sourceApp: "SideNotes", origin: .imported, createdAt: date, folderId: fid, hash: hash)
                let secrets = SecretDetector.find(in: text, loose: true)
                it.sensitive = !secrets.isEmpty
                it.ctype = secrets.isEmpty ? Classifier.classify(text) : (SecretDetector.isWholeSecret(text) ? .secret : .credential)
                if it.sensitive { res.withSecrets += 1 }
                store.save(it)
                res.notes += 1
            }
        }
        sqlite3_finalize(st)
        return res
    }
}

/// 从 Paste 搬家：拷一份它的库（Core Data，开着 WAL）到临时目录只读打开。
/// 复制历史进「最近复制」（按 Paste 里最后用过的时间排），各个 Pinboard 进抽屉、文件夹同名。Paste 里的原件不动。
public enum PasteImporter {
    public static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")
        return [
            lib.appendingPathComponent("Application Support/com.wiheads.paste-setapp"),   // Setapp 版
            lib.appendingPathComponent("Application Support/com.wiheads.paste"),          // 官网版
            lib.appendingPathComponent("Containers/com.wiheads.paste/Data/Library/Application Support/com.wiheads.paste"),  // App Store 版
        ].map { $0.appendingPathComponent("db.sqlite") }
    }

    public static var available: URL? { candidates.first { FileManager.default.fileExists(atPath: $0.path) } }

    public struct Entry {
        public var text: String?
        public var html: String?
        public var files: [String] = []
        public var image: Data?
        public var title: String?
        public var app: String?
        public var bundle: String?
        public var created: Date
        public var used: Date
        /// 在哪个 Pinboard 里；nil = 复制历史
        public var board: String?
        public init(text: String? = nil, app: String? = nil, created: Date, used: Date) {
            self.text = text; self.app = app; self.created = created; self.used = used
        }
    }

    public struct Result {
        public var clips = 0, kept = 0, images = 0, boards = 0
        public var skipped = 0, secrets = 0, unreadable = 0
    }

    /// 读出全部条目（不写手边的库）。home 是 db.sqlite 所在目录
    public static func read(_ db: URL) -> [Entry] {
        let dir = db.deletingLastPathComponent()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reach-paste-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tmp) }
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.copyItem(at: dir.appendingPathComponent("db.sqlite" + ext), to: tmp.appendingPathComponent("db.sqlite" + ext))
        }
        var h: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent("db.sqlite").path, &h, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(h) }
        let sql = """
        SELECT d.ZRAWPASTEBOARDITEMS, i.ZTITLE, a.ZNAME, a.ZBUNDLEIDENTIFIER, i.ZCREATEDAT, i.ZTIMESTAMP, l.ZNAME, l.ZRAWTYPE
        FROM ZITEMENTITY i JOIN ZITEMDATAENTITY d ON i.ZDATA = d.Z_PK
        LEFT JOIN ZAPPLICATIONENTITY a ON i.ZSOURCEAPPLICATION = a.Z_PK
        LEFT JOIN ZLISTENTITY l ON i.ZLIST = l.Z_PK
        ORDER BY i.ZTIMESTAMP
        """
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        func str(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }
        func date(_ i: Int32) -> Date { sqlite3_column_type(st, i) == SQLITE_NULL ? Date() : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, i)) }
        var out: [Entry] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let p = sqlite3_column_blob(st, 0) else { continue }
            let blob = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
            var e = Entry(app: str(2), created: date(4), used: date(5))
            e.title = str(1); e.bundle = str(3)
            // 列表类型 1 是复制历史本身，其余是 Pinboard
            if sqlite3_column_type(st, 7) != SQLITE_NULL, sqlite3_column_int(st, 7) != 1 { e.board = str(6) ?? "Paste" }
            guard let items = decode(blob, external: dir.appendingPathComponent(".db_SUPPORT/_EXTERNAL_DATA")) else {
                out.append(e); continue   // 读不出来的也占个位，好统计
            }
            fill(&e, from: items)
            out.append(e)
        }
        return out
    }

    /// Core Data 二进制字段：0x01 + 内容（LZFSE / bplist / deflate 压过的 JSON）；0x02 + 外部文件的 UUID
    public static func decode(_ blob: Data, external: URL) -> [[String: Any]]? {
        guard let first = blob.first else { return nil }
        var body = Data(blob.dropFirst())
        if first == 2 {
            let name = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            guard let d = try? Data(contentsOf: external.appendingPathComponent(name)) else { return nil }
            body = d
        }
        func parse(_ d: Data) -> [[String: Any]]? {
            if let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [[String: Any]] { return p }
            if let j = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] { return j }
            return nil
        }
        if let p = parse(body) { return p }
        for algo in [NSData.CompressionAlgorithm.lzfse, .zlib, .lz4, .lzma] {
            if let d = try? (body as NSData).decompressed(using: algo) as Data, let p = parse(d) { return p }
        }
        return nil
    }

    public static func fill(_ e: inout Entry, from items: [[String: Any]]) {
        func data(_ v: Any?) -> Data? {
            if let d = v as? Data { return d }
            if let s = v as? String { return Data(base64Encoded: s) ?? Data(s.utf8) }
            return nil
        }
        for it in items {
            guard let by = it["dataByType"] as? [String: Any] else { continue }
            func get(_ t: String) -> Data? { data(by[t]) }
            func text(_ t: String, _ enc: String.Encoding = .utf8) -> String? { get(t).flatMap { String(data: $0, encoding: enc) } }
            if let u = text("public.file-url"), let url = URL(string: u), url.isFileURL { e.files.append(url.path); continue }
            if e.text == nil {
                e.text = text("public.utf8-plain-text") ?? text("public.utf16-external-plain-text", .utf16) ?? text("public.utf16-plain-text", .utf16)
                    ?? text("public.text") ?? text("public.url")
            }
            if e.html == nil, let h = text("public.html"), h.utf8.count < 300_000 { e.html = h }
            if e.image == nil, e.text == nil, let img = get("public.png") ?? get("public.tiff") ?? get("public.jpeg") { e.image = img }
        }
        if let t = e.text, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { e.text = nil }
    }

    /// pngOf：把 TIFF/JPEG 转成 PNG（AppKit 里做，ReachCore 不依赖 AppKit）
    @discardableResult
    public static func importInto(_ store: Store, entries: [Entry], pngOf: (Data) -> Data?, now: Date = Date()) -> Result {
        var r = Result()
        let days = store.settings.retentionDays
        var boardsSeen = Set<String>()
        for e in entries {
            var it: Item
            if !e.files.isEmpty {
                let t = e.files.joined(separator: "\n")
                it = Item(kind: .clip, ctype: .file, text: t, files: e.files, hash: store.vault.fingerprint(Data(t.utf8)))
            } else if let t = e.text {
                guard t.utf8.count < 1_000_000 else { r.skipped += 1; continue }
                it = Item(kind: .clip, text: t, html: e.html, hash: store.vault.fingerprint(Data(t.utf8)))
                it.ctype = Classifier.classify(t)
            } else if let img = e.image, let png = pngOf(img), png.count < 20_000_000 {
                it = Item(kind: .clip, ctype: .image, text: "", hash: store.vault.fingerprint(png))
                if store.find(hash: it.hash, kind: .clip) != nil || store.find(hash: it.hash, kind: .kept) != nil { r.skipped += 1; continue }
                guard let f = store.saveImage(png) else { r.unreadable += 1; continue }
                it.imageFile = f
                r.images += 1
            } else { r.unreadable += 1; continue }

            if let b = e.board {
                if store.find(hash: it.hash, kind: .kept) != nil { r.skipped += 1; continue }
                let existed = store.folders.contains { $0.name == b }
                it.kind = .kept
                it.folderId = store.folder(named: b).id
                if !existed, boardsSeen.insert(b).inserted { r.boards += 1 }
                if let t = e.title { it.title = t }
            } else {
                if store.find(hash: it.hash, kind: .clip) != nil || store.find(hash: it.hash, kind: .kept) != nil { r.skipped += 1; continue }
            }
            let secrets = it.ctype == .image || it.ctype == .file ? [] : SecretDetector.find(in: it.text, loose: it.kind == .kept)
            it.sensitive = !secrets.isEmpty
            // 复制历史里整条是密钥的不搬：手边对复制到的密钥只留一小时，搬过来也是马上清掉
            if it.kind == .clip, it.ctype == .secret || (it.sensitive && SecretDetector.isWholeSecret(it.text)) { r.secrets += 1; continue }
            if it.kind == .kept, it.sensitive { it.ctype = SecretDetector.isWholeSecret(it.text) ? .secret : .credential }
            it.sourceApp = e.app
            it.sourceBundle = e.bundle
            it.origin = .imported
            it.createdAt = e.used
            it.updatedAt = e.used
            if it.kind == .clip {
                // 从搬家那天起算保留时间，不会一搬过来就过期；夹着密钥的只留一天
                it.expiresAt = it.sensitive ? now.addingTimeInterval(86400) : (days == 0 ? nil : now.addingTimeInterval(Double(days) * 86400))
                it.groupId = "paste-" + Self.dayKey(e.used)
                r.clips += 1
            } else { r.kept += 1 }
            store.save(it)
        }
        if r.clips > 0 { for (id, name) in groupNamesFor(entries) { store.setGroupName(id, name) } }
        return r
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    /// 搬来的历史按天成组，组名「从 Paste 搬来 · 11月3日」
    static func groupNamesFor(_ entries: [Entry]) -> [(String, String)] {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        var seen = Set<String>(), out: [(String, String)] = []
        for e in entries where e.board == nil {
            let k = dayKey(e.used)
            if seen.insert(k).inserted { out.append(("paste-" + k, "从 Paste 搬来 · " + f.string(from: e.used))) }
        }
        return out
    }
}
