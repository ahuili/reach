// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reach",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReachCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Reach", dependencies: ["ReachCore"]),
        // 命令行和 MCP 服务。App 里的可执行文件叫 Reach，同目录不能再有一个 reach（文件系统不分大小写），所以叫 reachctl，装到 PATH 时链接成 reach
        .executableTarget(name: "reachctl", dependencies: ["ReachCore"]),
        // CommandLineTools 环境没有 XCTest，用自测可执行文件代替
        .executableTarget(name: "ReachSelfTest", dependencies: ["ReachCore"]),
    ]
)
