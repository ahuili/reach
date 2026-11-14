import AppKit
import CryptoKit
import ReachCore

/// 菜单里的「检查更新」：从 GitHub 拿最新一版的 zip，核对 SHA256 和签名证书，换掉自己再重新打开。
/// 不用开终端，brew 装的和脚本装的都一样能用（brew 记的版本号会落后，之后 brew upgrade 再装一遍同一版也没关系）。
final class Updater {
    struct Release {
        var version: String
        var notes: String
        var zip: URL
        var sums: URL
        var page: URL?
    }

    let model: AppModel
    var testMode = false
    /// 自动检查发现的新版本（菜单里显示「更新到 v…」）
    private(set) var available: Release?
    private(set) var busy = false
    private var timer: Timer?

    init(model: AppModel) { self.model = model }

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private var latestURL: URL {
        if testMode, let s = ProcessInfo.processInfo.environment["REACH_UPDATE_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/ahuili/reach/releases/latest")!
    }

    /// 启动一分钟后查一次，之后每天一次；只在菜单里提示，不弹窗
    func startAutoCheck() {
        guard !testMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }

    func check(manual: Bool, done: ((Release?) -> Void)? = nil) {
        Task { @MainActor in
            let r = await self.fetchLatest()
            if let r, UpdateCheck.isNewer(r.version, than: Self.current) {
                let first = self.available?.version != r.version
                self.available = r
                if manual { self.ask(r) } else if first { self.model.toast("手边有新版本 v\(r.version)，点菜单栏图标 › 更新") }
            } else {
                self.available = nil
                if manual { self.model.toast(r == nil ? "没连上 GitHub，过会儿再试" : "已经是最新版 v\(Self.current)") }
            }
            done?(self.available)
        }
    }

    private func fetchLatest() async -> Release? {
        var req = URLRequest(url: latestURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = o["tag_name"] as? String,
              let assets = o["assets"] as? [[String: Any]] else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        func asset(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        guard let zip = asset("Reach-\(v).zip"), let sums = asset("SHA256SUMS-\(v).txt") else { return nil }
        return Release(version: v, notes: o["body"] as? String ?? "", zip: zip, sums: sums, page: (o["html_url"] as? String).flatMap(URL.init(string:)))
    }

    private func ask(_ r: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "更新到 v\(r.version)？"
        let notes = Markdown.toPlain(r.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        a.informativeText = "现在是 v\(Self.current)。手边会下载新版、核对校验和与签名，换好后自动重新打开，数据和权限都不变。\n\n" + (notes.count > 900 ? String(notes.prefix(900)) + "…" : notes)
        a.addButton(withTitle: "更新并重新打开")
        a.addButton(withTitle: "以后再说")
        if r.page != nil { a.addButton(withTitle: "看更新说明") }
        switch a.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: if let p = r.page { NSWorkspace.shared.open(p) }
        default: break
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case msg(String)
        var description: String { if case .msg(let s) = self { return s }; return "" }
    }

    /// 下载、核对、换掉自己。done 只在测试模式里用（测试模式不退出、不重新打开）
    func install(_ r: Release, done: ((String?) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        model.toast("正在下载 v\(r.version)…")
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let newApp = try await self.prepare(r)
                try self.swap(to: newApp)
                done?(nil)
            } catch {
                self.model.toast("没更新成：\(error)")
                done?("\(error)")
            }
        }
    }

    private func prepare(_ r: Release) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("reach-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let (zipFile, zr) = try? await URLSession.shared.download(from: r.zip), (zr as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.msg("下载失败") }
        guard let (sumData, sr) = try? await URLSession.shared.data(from: r.sums), (sr as? HTTPURLResponse)?.statusCode == 200,
              let expected = UpdateCheck.sha(for: "Reach-\(r.version).zip", in: String(decoding: sumData, as: UTF8.self)) else { throw Failure.msg("拿不到校验和") }
        let zip = work.appendingPathComponent("Reach.zip")
        try FileManager.default.moveItem(at: zipFile, to: zip)
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure.msg("校验和对不上，下载的文件可能被改过") }
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]).status == 0 else { throw Failure.msg("解压失败") }
        let app = work.appendingPathComponent("Reach.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == r.version else { throw Failure.msg("下载的不是这个版本的手边") }
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else { throw Failure.msg("新版的签名不完整") }
        // 必须和现在这个用同一张证书签的：换了证书就不认（也保证辅助功能、屏幕录制的授权不会掉）
        let mine = Self.authority(Bundle.main.bundlePath), theirs = Self.authority(app.path)
        guard let mine, mine == theirs else { throw Failure.msg("新版的签名证书和现在的不一样（\(theirs ?? "无")），没有替换") }
        return app
    }

    private func swap(to newApp: URL) throws {
        let dest = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
            throw Failure.msg("没有权限写 \(dest.deletingLastPathComponent().path)，用 brew upgrade --cask reach 或重新跑安装脚本")
        }
        // 等手边退出，再把旧的挪开、新的放进去；放失败就把旧的挪回来
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && /usr/bin/ditto "$3" "$2"; then
          /usr/bin/xattr -dr com.apple.quarantine "$2" 2>/dev/null
          rm -rf "$2.old"
        else
          rm -rf "$2"; mv "$2.old" "$2"
        fi
        rm -rf "$(dirname "$3")"
        [ "$4" = "1" ] && /usr/bin/open "$2"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), dest.path, newApp.path, testMode ? "0" : "1"]
        try p.run()
        NSApp.terminate(nil)
    }

    private static func authority(_ path: String) -> String? {
        run("/usr/bin/codesign", ["-dvv", path]).output.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) }
    }

    @discardableResult
    private static func run(_ bin: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }
}
