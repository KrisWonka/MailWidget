import Foundation
import XCTest

/// 这段脚本是生成出来的文本，在真机上连续藏过三个 bug，且原先长在 app target 里、单测
/// 够不着。这里既校验它作为 shell 脚本语法成立（`bash -n`），也逐条钉住那三个真机教训。
final class LaunchAgentRunnerScriptTests: XCTestCase {
    private let payloadPath = "/Users/someone/Library/Application Support/GmailDailyWidget/latest.json"
    private let ingestCommand = "\"/Applications/MailWidget.app/Contents/MacOS/MailWidget\" --ingest \"/Users/someone/Library/Application Support/GmailDailyWidget/latest.json\" --source codex"

    private func script(executablePath: String? = nil, withFallback: Bool = true) -> String {
        LaunchAgentRunnerScript.make(
            command: "\"/opt/homebrew/bin/codex\" exec --skip-git-repo-check \"$(cat /tmp/prompt.md)\"",
            executablePath: executablePath,
            fallbackIngest: withFallback ? (payloadPath: payloadPath, command: ingestCommand) : nil
        )
    }

    /// `bash -n` 只解析不执行——生成的脚本里有多层嵌套的 `$(...)`、`( ... ) &`、字符串插值，
    /// 任何一处拼错都会在这里暴露，而不是等到某天早上 9 点静默失败。
    private func assertParsesAsBash(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runner-\(UUID().uuidString).sh")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0,
            "bash -n 拒绝了生成的脚本：\(String(decoding: errorData, as: UTF8.self))",
            file: file, line: line
        )
    }

    func testScriptIsValidBash() throws {
        try assertParsesAsBash(script(executablePath: "/opt/homebrew/bin/codex"))
    }

    func testScriptWithoutFallbackIsValidBash() throws {
        try assertParsesAsBash(script(withFallback: false))
    }

    // MARK: - 真机教训 1：PATH

    func testExportsPathBeforeRunningCommand() {
        let source = script()
        let exportIndex = try? XCTUnwrap(source.range(of: "export PATH="))
        XCTAssertNotNil(exportIndex, "脚本里没有 export PATH")
        guard let export = source.range(of: "export PATH="),
              let loop = source.range(of: "for attempt in") else {
            return XCTFail("缺少 export PATH 或主循环")
        }
        XCTAssertTrue(export.lowerBound < loop.lowerBound, "export PATH 必须在跑命令之前")
        XCTAssertTrue(source.contains("/opt/homebrew/bin"), "PATH 里没有 Homebrew 的 bin")
    }

    // MARK: - 真机教训 2：工作目录

    /// launchd 的 cwd 是 `/`，codex 据此把沙箱降级成 read-only，日报载荷写不出来。
    func testPinsWorkingDirectoryToHome() {
        let source = script()
        XCTAssertTrue(source.contains("cd \"$HOME\""), "脚本没有把工作目录钉在 home")
        guard let cd = source.range(of: "cd \"$HOME\""),
              let loop = source.range(of: "for attempt in") else {
            return XCTFail("缺少 cd 或主循环")
        }
        XCTAssertTrue(cd.lowerBound < loop.lowerBound, "cd 必须在跑命令之前")
    }

    // MARK: - 真机教训 3：兜底发布不看退出码

    /// codex 完整写出载荷后在写游标那步撞上额度上限而 exit 1——兜底发布必须照样把那份
    /// 载荷发出去，而不是锁在 `status -eq 0` 分支里。
    func testFallbackPublishRunsRegardlessOfExitStatus() throws {
        let source = script()
        let ingestLine = try XCTUnwrap(source.range(of: "--ingest"))
        let successBranch = try XCTUnwrap(source.range(of: "if [ \"$status\" -eq 0 ]; then"))
        // 兜底发布出现在第一个 `status -eq 0` 判断之后，说明它没有被包在那个分支体里；
        // 更强的保证由下面的整脚本执行测试给出。
        XCTAssertTrue(successBranch.lowerBound < ingestLine.lowerBound)
    }

    /// 真正的证明：把脚本跑起来，让"命令"故意以非零码退出但写出一份新载荷，断言 ingest
    /// 仍然被执行。`bash -n` 只管语法，这条管语义。
    func testFallbackPublishActuallyRunsWhenCommandFails() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runner-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = directory.appendingPathComponent("latest.json").path
        let marker = directory.appendingPathComponent("ingested").path
        // 模拟 2026-09-13 那次：写出载荷，然后非零退出。
        let failingCommand = "/bin/sh -c 'echo payload > \"\(payload)\"; exit 1'"
        let source = LaunchAgentRunnerScript.make(
            command: failingCommand,
            executablePath: nil,
            fallbackIngest: (payloadPath: payload, command: "/usr/bin/touch \"\(marker)\"")
        )

        let scriptURL = directory.appendingPathComponent("run.sh")
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker),
            "命令以非零码退出但写出了新载荷，兜底发布没有执行"
        )
        XCTAssertEqual(process.terminationStatus, 0, "兜底发布成功后脚本应当以 0 退出，不再重试")
    }

    /// 新鲜度判定已经从脚本里搬走——脚本只负责把**本次尝试的起始时刻**交给
    /// `--ingest --not-before`，由 `DailySummaryPublisher.freshnessDecision` 统一裁决。
    ///
    /// 这条原本断言的是"脚本自己跳过陈旧载荷"。那份 shell 判据比 Swift 那份宽松
    /// （只比 mtime、不比 generatedAt），两份实现各自演进正是这个仓库最主要的 bug 来源，
    /// 所以判定收归一处，这里改为钉住"时刻确实被传下去了"。真正的判定逻辑由
    /// `DailyRegeneratorFallbackPublishTests` 覆盖。
    func testFallbackDelegatesFreshnessToIngest() {
        let source = LaunchAgentRunnerScript.make(
            command: "/usr/bin/true",
            executablePath: nil,
            fallbackIngest: (payloadPath: "/tmp/p.json", command: "/usr/bin/true")
        )
        XCTAssertTrue(
            source.contains("--not-before \"$attempt_started\""),
            "脚本没有把本次尝试的起始时刻交给 ingest\n\(source)"
        )
        XCTAssertFalse(
            source.contains("/usr/bin/stat -f %m"),
            "脚本里还留着自己那份 mtime 判据，应该已经搬到发布层了"
        )
    }

    /// CLI 预检：坏 CLI 不该让定时任务白跑满三轮重试。
    func testPreflightRejectsAnUnusableCLIBeforeLooping() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runner-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 一个 --version 就失败的假 CLI。
        let cli = directory.appendingPathComponent("brokencli")
        try "#!/bin/sh\nexit 3\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let marker = directory.appendingPathComponent("ran").path
        let script = LaunchAgentRunnerScript.make(
            command: "/usr/bin/touch \"\(marker)\"",
            executablePath: cli.path
        )
        let scriptURL = directory.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker),
            "CLI 预检没拦住：命令仍然被执行了"
        )
        XCTAssertEqual(process.terminationStatus, 1, "预检失败应当直接退出 1，不进重试循环")
    }

    /// 「生成中」标志：定时任务也要标记，否则它跑的时候用户点 ↻ 会并发起第二个 agent。
    /// `trap ... EXIT` 保证异常退出也清得掉。
    func testMarkerIsSetAndAlwaysCleared() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runner-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let trace = directory.appendingPathComponent("trace").path
        let marker = directory.appendingPathComponent("mark.sh")
        try "#!/bin/sh\necho \"$1\" >> \"\(trace)\"\n".write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: marker.path)

        // `/usr/bin/true` 而不是 `/bin/true`：macOS 上没有后者，写错会让命令以 127 失败、
        // 脚本跑满三轮重试（每轮 sleep 60），这条测试就要跑 180 秒。
        let script = LaunchAgentRunnerScript.make(
            command: "/usr/bin/true",
            executablePath: nil,
            markerCommand: "\"\(marker.path)\""
        )
        let scriptURL = directory.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let recorded = (try? String(contentsOfFile: trace, encoding: .utf8)) ?? ""
        XCTAssertTrue(recorded.contains("start"), "没有标记开始\n\(recorded)")
        XCTAssertTrue(recorded.contains("end"), "退出时没有清掉标记\n\(recorded)")
    }
}
