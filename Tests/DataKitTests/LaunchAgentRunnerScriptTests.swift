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

    /// 反向约束：载荷是上一次留下的旧件（mtime 早于本次尝试）时不得重复发布。
    func testFallbackPublishSkipsStalePayload() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runner-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = directory.appendingPathComponent("latest.json").path
        let marker = directory.appendingPathComponent("ingested").path
        FileManager.default.createFile(atPath: payload, contents: Data("old".utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: payload
        )

        let source = LaunchAgentRunnerScript.make(
            command: "/bin/sh -c 'exit 1'",
            executablePath: nil,
            fallbackIngest: (payloadPath: payload, command: "/usr/bin/touch \"\(marker)\"")
        )
        // 三次尝试之间各 sleep 60s，测试里只跑到第一次判断即可——把重试间隔的 sleep
        // 换成瞬时，避免测试挂 3 分钟。
        let fast = source.replacingOccurrences(of: "/bin/sleep 60", with: "/usr/bin/true")
        let scriptURL = directory.appendingPathComponent("run.sh")
        try fast.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker),
            "陈旧载荷不该被兜底发布"
        )
        XCTAssertEqual(process.terminationStatus, 1, "三次都失败且无新载荷，脚本应当以 1 退出")
    }
}
