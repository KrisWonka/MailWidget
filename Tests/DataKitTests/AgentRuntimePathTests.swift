import Foundation
import XCTest

/// 2026-09-13 第二台机器真机故障的回归测试：Codex 的 launchd 日报任务连续三次
/// `exit 127`，日志只有 `env: node: No such file or directory`——脚本里 codex 是绝对
/// 路径，但它是个 `#!/usr/bin/env node` 的 npm 壳，解释器仍要走 PATH 找。
final class AgentRuntimePathTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentRuntimePathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func makeFile(_ name: String, contents: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - shebang 解析

    func testParsesEnvShebang() throws {
        // 逐字取自真机上的 /opt/homebrew/bin/codex 头两行。
        let path = try makeFile("codex", contents: """
        #!/usr/bin/env node
        // Unified entry point for the Codex CLI.
        """)
        XCTAssertEqual(AgentRuntimePath.shebangInterpreter(of: path), .viaEnv("node"))
    }

    func testParsesEnvShebangWithSplitFlag() throws {
        let path = try makeFile("tool", contents: "#!/usr/bin/env -S node --enable-source-maps\n")
        XCTAssertEqual(AgentRuntimePath.shebangInterpreter(of: path), .viaEnv("node"))
    }

    func testParsesAbsoluteShebang() throws {
        let path = try makeFile("script.sh", contents: "#!/bin/bash\necho hi\n")
        XCTAssertEqual(AgentRuntimePath.shebangInterpreter(of: path), .absolute("/bin/bash"))
    }

    /// 原生二进制（claude 在本机就是）读到的头两字节不是 `#!`，必须安静返回 nil 而不是
    /// 把 Mach-O 头当成解释器名。
    func testBinaryHasNoShebang() throws {
        let url = directory.appendingPathComponent("native")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]).write(to: url)
        XCTAssertNil(AgentRuntimePath.shebangInterpreter(of: url.path))
    }

    func testMissingFileHasNoShebang() {
        XCTAssertNil(AgentRuntimePath.shebangInterpreter(of: directory.appendingPathComponent("nope").path))
    }

    // MARK: - 解释器名的输入校验

    /// shebang 来自磁盘上的文件，内容不完全可控——解释器名会被拼进 `zsh -lc` 的命令行，
    /// 带 shell 元字符的一律拒绝解析，而不是原样拼进去。
    func testRejectsInterpreterNameWithShellMetacharacters() {
        for hostile in ["node; touch /tmp/pwned", "node$(id)", "node`id`", "node|cat", ""] {
            XCTAssertNil(AgentRuntimePath.resolveViaLoginShell(hostile), "不该解析 \(hostile)")
        }
    }

    // MARK: - 目录推导

    func testIncludesExecutableOwnDirectory() throws {
        let path = try makeFile("thing", contents: "#!/bin/bash\n")
        XCTAssertEqual(AgentRuntimePath.directoriesNeeded(toRun: path).first, directory.path)
    }

    /// 真机复现：一个 `env node` 壳，推导出的目录必须包含 node 真正所在的目录，否则
    /// launchd 跑起来还是 127。node 不一定装在测试机上，没有就只断言不崩。
    func testResolvesEnvInterpreterDirectory() throws {
        let path = try makeFile("npm-shim", contents: "#!/usr/bin/env node\n")
        let directories = AgentRuntimePath.directoriesNeeded(toRun: path)
        XCTAssertTrue(directories.contains(directory.path))
        if let node = AgentRuntimePath.resolveViaLoginShell("node") {
            XCTAssertTrue(
                directories.contains((node as NSString).deletingLastPathComponent),
                "解析出的目录 \(directories) 里没有 node 所在的 \(node)"
            )
        }
    }

    // MARK: - 生成的 PATH

    func testExportStatementPutsExtrasFirstAndKeepsInheritedPath() {
        let statement = AgentRuntimePath.exportStatement(extraDirectories: ["/custom/bin"])
        XCTAssertTrue(statement.hasPrefix("export PATH=\"/custom/bin:"), statement)
        XCTAssertTrue(statement.hasSuffix(":$PATH\""), statement)
        XCTAssertTrue(statement.contains("/opt/homebrew/bin"), statement)
        XCTAssertTrue(statement.contains("/usr/bin"), statement)
    }

    func testExportStatementDeduplicates() {
        let statement = AgentRuntimePath.exportStatement(extraDirectories: ["/opt/homebrew/bin", "/opt/homebrew/bin"])
        let body = statement
            .replacingOccurrences(of: "export PATH=\"", with: "")
            .replacingOccurrences(of: ":$PATH\"", with: "")
        let occurrences = body.split(separator: ":").filter { $0 == "/opt/homebrew/bin" }
        XCTAssertEqual(occurrences.count, 1, body)
    }

    func testExpandedEnvironmentPrependsExtras() throws {
        let environment = AgentRuntimePath.expandedEnvironment(extraDirectories: ["/custom/bin"])
        let path = try XCTUnwrap(environment["PATH"])
        XCTAssertEqual(path.split(separator: ":").first.map(String.init), "/custom/bin")
    }
}
