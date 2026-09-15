import Foundation
import XCTest

/// 这个项目连续三天每天爆 bug，归类后几乎全是同一个形状：**同一件事在两条路径上各写一份，
/// 改一处漏一处**。这组测试就是为了让"漏一处"当场失败，而不是等用户在桌面上发现。
///
/// 覆盖的路径：
///   A = app 内点刷新（`DailyRegenerator` → `Process`）
///   B = launchd 定时任务（`DailySourceInstaller` → `LaunchAgentRunnerScript` → shell）
final class AgentInvocationParityTests: XCTestCase {
    private let sources = [DailySource.codex, DailySource.claude]

    /// 核心不变式：两条路径喂给 CLI 的参数必须逐个一致、顺序一致。
    /// `--permission-mode auto` 就是栽在这里——2026-08-25 加进 B，A 从功能引入起没动过，
    /// 直到 2026-09-14 才发现，中间换台机器就会卡死。
    func testBothPathsPassTheSameFlagsInTheSameOrder() {
        for source in sources {
            let flags = AgentInvocation.flags(for: source)

            // A：去掉最后一个提示词位置参数，剩下的就是参数表。
            let processArguments = AgentInvocation.arguments(for: source, prompt: "PROMPT")
            XCTAssertEqual(Array(processArguments.dropLast()), flags, "来源 \(source)：app 内路径的参数与定义不符")
            XCTAssertEqual(processArguments.last, "PROMPT", "来源 \(source)：提示词必须是最后一个位置参数")

            // B：从 shell 命令里把参数按顺序抠出来。
            let shell = AgentInvocation.shellCommand(
                executablePath: "/opt/homebrew/bin/agent",
                source: source,
                promptFileExpression: "{PROMPT_FILE}"
            )
            for flag in flags {
                XCTAssertTrue(shell.contains(flag), "来源 \(source)：launchd 命令里缺少 \(flag)\n\(shell)")
            }
            // 顺序也要一致，不能只是"都出现了"。
            var searchRange = shell.startIndex..<shell.endIndex
            for flag in flags {
                guard let found = shell.range(of: flag, range: searchRange) else {
                    return XCTFail("来源 \(source)：\(flag) 顺序不对\n\(shell)")
                }
                searchRange = found.upperBound..<shell.endIndex
            }
        }
    }

    /// 两条路径都必须关掉 agent 的 stdin。A 用 `standardInput = FileHandle.nullDevice`
    /// （注释写明"真机首跑实测 codex 会等额外的 stdin 输入，继承了打开的管道就会挂起"），
    /// B 一直没关——第二台机器的日志里能看到 codex 打 `Reading additional input from stdin...`。
    func testLaunchdCommandClosesStdin() {
        for source in sources {
            let shell = AgentInvocation.shellCommand(
                executablePath: "/opt/homebrew/bin/agent",
                source: source,
                promptFileExpression: "{PROMPT_FILE}"
            )
            XCTAssertTrue(shell.contains("< /dev/null"), "来源 \(source)：launchd 命令没有关掉 stdin\n\(shell)")
        }
    }

    /// 可执行文件路径和提示词文件都必须加引号——两者都含空格的真实路径
    /// （`Application Support`）。
    func testPathsAreQuoted() {
        let shell = AgentInvocation.shellCommand(
            executablePath: "/Users/someone/.local/bin/claude",
            source: DailySource.claude,
            promptFileExpression: "\"/Users/someone/Library/Application Support/GmailDailyWidget/prompt-claude.md\""
        )
        XCTAssertTrue(shell.hasPrefix("\"/Users/someone/.local/bin/claude\""), shell)
        XCTAssertTrue(shell.contains("\"$(cat \"/Users/someone/Library/Application Support/GmailDailyWidget/prompt-claude.md\")\""), shell)
    }

    /// 生成出来的整条 launchd 脚本必须仍是合法 shell —— 加 `< /dev/null` 时很容易把
    /// 重定向放到 `&` 后面之类的位置。
    func testGeneratedScriptStillParsesAsBash() throws {
        let command = AgentInvocation.shellCommand(
            executablePath: "/opt/homebrew/bin/codex",
            source: DailySource.codex,
            promptFileExpression: "\"/tmp/prompt.md\""
        )
        let script = LaunchAgentRunnerScript.make(command: command, executablePath: "/opt/homebrew/bin/codex")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parity-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let errorText = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "bash -n 拒绝了生成的脚本：\(errorText)")
    }

    /// codex 与 claude 的参数不能相同——真出现相同说明 switch 写塌了。
    func testEnginesDifferMeaningfully() {
        XCTAssertNotEqual(
            AgentInvocation.flags(for: DailySource.codex),
            AgentInvocation.flags(for: DailySource.claude)
        )
        XCTAssertTrue(AgentInvocation.flags(for: DailySource.codex).contains("--skip-git-repo-check"))
        XCTAssertTrue(AgentInvocation.flags(for: DailySource.claude).contains("--permission-mode"))
    }
}
