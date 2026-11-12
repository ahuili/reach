import Foundation
import SQLite3

/// 从 SideNotes 搬家：只读打开它的本地库，按原文件夹建好留存。
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

public enum AIError: Error { case notReady, http(Int, String), bad }

/// 最简单的 OpenAI 兼容接口调用。发出去之前调用方必须先把密钥抹掉（SecretDetector.redact）。
public struct AIClient {
    public let cfg: AISettings
    public init(_ cfg: AISettings) { self.cfg = cfg }

    public func complete(system: String, user: String, maxTokens: Int = 600, timeout: TimeInterval = 40) async throws -> String {
        guard cfg.isReady else { throw AIError.notReady }
        var base = cfg.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.bad }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty { req.setValue("Bearer \(cfg.apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = ["model": cfg.model, "temperature": 0.2, "max_tokens": maxTokens,
                                   "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw AIError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "") }
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else { throw AIError.bad }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
