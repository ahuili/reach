import Foundation
import CryptoKit
import Security

public enum ReachPaths {
    /// 数据目录。测试时用环境变量 REACH_HOME 指到别处。
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["REACH_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reach", isDirectory: true)
    }

    /// 旧版（页边 Margin）的数据目录搬到新名字下。旧目录里还有库，就说明还没搬过。
    /// 新目录如果已经有了（上一次搬失败时建的空库），挪到一边留着，不删。返回 true 表示这次搬了。
    @discardableResult
    public static func migrateLegacy() -> Bool {
        guard ProcessInfo.processInfo.environment["REACH_HOME"] == nil else { return false }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Margin", isDirectory: true)
        guard fm.fileExists(atPath: old.appendingPathComponent("margin.sqlite").path) else { return false }
        do {
            if fm.fileExists(atPath: home.path) {
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
                try fm.moveItem(at: home, to: base.appendingPathComponent("Reach-搬家前-" + f.string(from: Date())))
            }
            try? fm.removeItem(at: old.appendingPathComponent("margin.sock"))
            try fm.moveItem(at: old, to: home)
        } catch {
            NSLog("Reach: 搬旧数据失败 \(error)")
            return false
        }
        for suffix in ["", "-wal", "-shm"] {
            let a = home.appendingPathComponent("margin.sqlite" + suffix)
            if fm.fileExists(atPath: a.path) { try? fm.moveItem(at: a, to: home.appendingPathComponent("reach.sqlite" + suffix)) }
        }
        return true
    }

    public static var db: URL { home.appendingPathComponent("reach.sqlite") }
    public static var images: URL { home.appendingPathComponent("images", isDirectory: true) }
    public static var socket: String {
        // unix socket 路径长度上限约 104 字节，数据目录太深时退到 /tmp
        let p = home.appendingPathComponent("reach.sock").path
        if p.utf8.count < 100 { return p }
        // 用固定算法算指纹：App 和命令行是两个进程，必须算出同一个路径
        var h: UInt64 = 0xcbf29ce484222325
        for b in p.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "/tmp/reach-\(getuid())-\(h % 1_000_000).sock"
    }
    public static func ensure() {
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        // 数据目录只有自己能读
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}

public enum CryptoError: Error { case keychain(OSStatus), badData }

/// 整库加密用的密钥，放在数据目录里的 db.key（权限 600，只有你的账号能读）。
/// 以前放在系统钥匙串：自签名的 App 没有开发者团队编号，钥匙串按每一版程序的指纹认人，每次升级都要输一次密码，所以搬出来。
/// 旧版存在钥匙串里的密钥，第一次启动时读一次（系统最后问一次），写进文件。测试（REACH_KEYFILE=1）用 test.key。
public struct Vault {
    public let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    /// migrated：刚从旧版搬来，库是旧密钥加密的，要用旧密钥（并把它存到新名字下）
    public static func open(migrated: Bool = false) throws -> Vault {
        if ProcessInfo.processInfo.environment["REACH_KEYFILE"] == "1" {
            return Vault(key: try fileKey())
        }
        ReachPaths.ensure()
        let url = keyFile
        // 刚从页边 Margin 搬来：库是旧密钥加密的，用旧密钥
        if migrated {
            let (ost, old) = read(legacyService)
            guard ost == errSecSuccess, let od = old, od.count == 32 else { throw CryptoError.keychain(ost == errSecSuccess ? errSecDecode : ost) }
            try writeKey(od, to: url)
            return Vault(key: SymmetricKey(data: od))
        }
        if let d = try? Data(contentsOf: url), d.count == 32 { return Vault(key: SymmetricKey(data: d)) }
        // 还没有密钥文件：以前的版本把密钥放在钥匙串里，读出来搬到文件
        let (st, cur) = read(service)
        if st == errSecSuccess, let d = cur, d.count == 32 { try writeKey(d, to: url); return Vault(key: SymmetricKey(data: d)) }
        if FileManager.default.fileExists(atPath: ReachPaths.db.path) {
            if st != errSecItemNotFound { throw CryptoError.keychain(st) }
            let (ost, old) = read(legacyService)
            guard ost == errSecSuccess, let od = old, od.count == 32 else { throw CryptoError.keychain(ost == errSecSuccess ? errSecDecode : ost) }
            try writeKey(od, to: url)
            return Vault(key: SymmetricKey(data: od))
        }
        let k = SymmetricKey(size: .bits256)
        try writeKey(k.withUnsafeBytes { Data($0) }, to: url)
        return Vault(key: k)
    }

    public static var keyFile: URL { ReachPaths.home.appendingPathComponent("db.key") }

    static func writeKey(_ d: Data, to url: URL) throws {
        // 先建好只有自己能读的空文件再写，中间不留别人能读的窗口
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try d.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func fileKey() throws -> SymmetricKey {
        ReachPaths.ensure()
        let url = ReachPaths.home.appendingPathComponent("test.key")
        if let d = try? Data(contentsOf: url), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        try d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return k
    }

    static let service = "me.ahuili.reach"
    /// 旧版（页边 Margin）存密钥用的名字
    static let legacyService = "me.ahuili.margin"
    static let account = "db-key"

    static func read(_ svc: String) -> (OSStatus, Data?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(query as CFDictionary, &out)
        return (st, out as? Data)
    }

    public func seal(_ data: Data) throws -> Data {
        guard let c = try AES.GCM.seal(data, using: key).combined else { throw CryptoError.badData }
        return c
    }

    public func open(_ data: Data) throws -> Data {
        try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key)
    }

    /// 带密钥的内容指纹：用于去重，库文件里看不出原文
    public func fingerprint(_ data: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
