import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 加密的本地库。每一行的内容都用 AES-GCM 加密，明文只在内存里。
/// 条目数量是几千级，启动时全部解密进内存，搜索和排序都在内存里做。
public final class Store {
    public let vault: Vault
    private var db: OpaquePointer?
    public private(set) var items: [String: Item] = [:]
    public private(set) var folders: [Folder] = []
    public var settings = Settings() { didSet { if settings != oldValue { setKV("settings", settings) } } }
    /// 分组的名字（groupId → 名字）
    public private(set) var groupNames: [String: String] = [:]
    /// 项目里某个配置名固定用哪条留存（project → name → itemId）
    public private(set) var bindings: [String: [String: String]] = [:]

    public init(vault: Vault) throws {
        self.vault = vault
        ReachPaths.ensure()
        guard sqlite3_open(ReachPaths.db.path, &db) == SQLITE_OK else { throw CryptoError.badData }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ReachPaths.db.path)
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, kind TEXT, created REAL, expires REAL, data BLOB)")
        exec("CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, data BLOB)")
        loadAll()
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func loadAll() {
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT data FROM items", -1, &st, nil) == SQLITE_OK {
            let dec = JSONDecoder()
            while sqlite3_step(st) == SQLITE_ROW {
                guard let p = sqlite3_column_blob(st, 0) else { continue }
                let d = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
                if let plain = try? vault.open(d), let it = try? dec.decode(Item.self, from: plain) { items[it.id] = it }
            }
        }
        sqlite3_finalize(st)
        folders = getKV("folders", [Folder].self) ?? []
        settings = getKV("settings", Settings.self) ?? Settings()
        groupNames = getKV("groupNames", [String: String].self) ?? [:]
        bindings = getKV("bindings", [String: [String: String]].self) ?? [:]
    }

    // MARK: 键值

    public func getKV<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "SELECT data FROM kv WHERE key=?", -1, &st, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { return nil }
        let d = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 0)))
        guard let plain = try? vault.open(d) else { return nil }
        return try? JSONDecoder().decode(T.self, from: plain)
    }

    public func setKV<T: Encodable>(_ key: String, _ value: T) {
        guard let plain = try? JSONEncoder().encode(value), let sealed = try? vault.seal(plain) else { return }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv(key,data) VALUES(?,?)", -1, &st, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(st, 1, key, -1, SQLITE_TRANSIENT)
        _ = sealed.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT) }
        sqlite3_step(st)
    }

    // MARK: 条目

    public func save(_ item: Item) {
        var it = item
        it.updatedAt = Date()
        items[it.id] = it
        guard let plain = try? JSONEncoder().encode(it), let sealed = try? vault.seal(plain) else { return }
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO items(id,kind,created,expires,data) VALUES(?,?,?,?,?)", -1, &st, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(st, 1, it.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(st, 2, it.kind.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(st, 3, it.createdAt.timeIntervalSince1970)
        if let e = it.expiresAt { sqlite3_bind_double(st, 4, e.timeIntervalSince1970) } else { sqlite3_bind_null(st, 4) }
        _ = sealed.withUnsafeBytes { sqlite3_bind_blob(st, 5, $0.baseAddress, Int32(sealed.count), SQLITE_TRANSIENT) }
        sqlite3_step(st)
    }

    public func delete(_ id: String) {
        if let f = items[id]?.imageFile { try? FileManager.default.removeItem(at: ReachPaths.images.appendingPathComponent(f)) }
        items[id] = nil
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, "DELETE FROM items WHERE id=?", -1, &st, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(st)
    }

    /// 清掉过期的复制记录；常用的（贴过三次以上且两个月内用过）不清。返回清掉的条数。
    @discardableResult
    public func purgeExpired(now: Date = Date(), maxClips: Int = 3000) -> Int {
        var dead: [String] = []
        for it in items.values where it.kind == .clip {
            guard let e = it.expiresAt, e < now else { continue }
            if !it.sensitive, Store.isCommon(it, now: now) { continue }
            dead.append(it.id)
        }
        let clips = items.values.filter { $0.kind == .clip && !dead.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
        if clips.count > maxClips { dead += clips[maxClips...].filter { !Store.isCommon($0, now: now) }.map(\.id) }
        dead.forEach(delete)
        return dead.count
    }

    public static func isCommon(_ it: Item, now: Date = Date()) -> Bool {
        guard it.useCount >= 3, let u = it.lastUsedAt else { return false }
        return now.timeIntervalSince(u) < 60 * 86400
    }

    public var clips: [Item] { items.values.filter { $0.kind == .clip }.sorted { $0.createdAt > $1.createdAt } }
    public var kept: [Item] { items.values.filter { $0.kind == .kept }.sorted { $0.createdAt > $1.createdAt } }

    public func find(hash: String, kind: ItemKind) -> Item? {
        items.values.first { $0.hash == hash && $0.kind == kind }
    }

    public func recordUse(_ id: String, app: String?) {
        guard var it = items[id] else { return }
        it.useCount += 1
        it.lastUsedAt = Date()
        if let a = app { it.useByApp[a, default: 0] += 1 }
        save(it)
    }

    // MARK: 文件夹

    public func saveFolders(_ f: [Folder]) { folders = f; setKV("folders", f) }

    @discardableResult
    public func folder(named name: String) -> Folder {
        if let f = folders.first(where: { $0.name == name }) { return f }
        let f = Folder(name: name, order: (folders.map(\.order).max() ?? 0) + 1)
        saveFolders(folders + [f])
        return f
    }

    public func renameFolder(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !folders.contains(where: { $0.name == n && $0.id != id }) else { return }
        saveFolders(folders.map { var f = $0; if f.id == id { f.name = n }; return f })
    }

    /// 上移（-1）或下移（+1）一位
    public func moveFolder(_ id: String, by d: Int) {
        var f = folders.sorted { $0.order < $1.order }
        guard let i = f.firstIndex(where: { $0.id == id }), f.indices.contains(i + d) else { return }
        f.swapAt(i, i + d)
        saveFolders(f.enumerated().map { var x = $0.element; x.order = $0.offset; return x })
    }

    public func removeFolder(_ id: String) {
        for it in items.values where it.folderId == id { var x = it; x.folderId = nil; save(x) }
        saveFolders(folders.filter { $0.id != id })
    }

    public func setGroupName(_ id: String, _ name: String) { groupNames[id] = name; setKV("groupNames", groupNames) }

    public func bind(project: String, name: String, itemId: String) {
        bindings[project, default: [:]][name] = itemId
        setKV("bindings", bindings)
    }

    // MARK: 图片

    public func saveImage(_ png: Data) -> String? {
        let name = UUID().uuidString + ".bin"
        guard let sealed = try? vault.seal(png) else { return nil }
        do { try sealed.write(to: ReachPaths.images.appendingPathComponent(name), options: .atomic); return name } catch { return nil }
    }

    public func loadImage(_ name: String) -> Data? {
        guard let d = try? Data(contentsOf: ReachPaths.images.appendingPathComponent(name)) else { return nil }
        return try? vault.open(d)
    }
}
