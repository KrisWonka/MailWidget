// DailyRegenerator.swift
// DataKit — 宿主侧「重新生成」执行器：widget 上的按钮触发一次日报重新生成，立即返回不阻塞。
//
// 只负责启动外部 agent 进程（Codex/Claude）并维护一个"进行中"标志；日报本体的落盘、
// --ingest、来源仲裁全部沿用既有链路——`DailySummaryPromptTemplate.render(for:)` 渲染出的
// 提示词里已经包含完整的三步契约（写 latest.json → 调 --ingest → 推进游标，见设计文档 §8）。
// 这里不等待、不解析 agent 是否真的成功发布了新日报：`--ingest` 成功时 App 自己会
// reload；这里的 terminationHandler 只是异常兜底（agent 中途失败、被杀死等），
// 确保"重新生成中"标志和 widget 不会永远卡住。

import Foundation
import WidgetKit

enum DailyRegenerator {

    /// App Group UserDefaults 里记录"重新生成已启动"的时间戳。
    static let startedAtKey = "dailyRegenerateStartedAt"

    /// 超过这个时长视为过期。agent 一次真实运行远低于 15 分钟；这是防止进程被杀死、
    /// 系统睡眠等异常打断 terminationHandler 后，widget 永久卡在"重新生成中"的兜底。
    static let staleAfter: TimeInterval = 15 * 60

    /// widget 头部翻页键左侧要 reload 的两个 kind：日报 widget 与 Mail widget。
    /// 两个都 reload 不会造成额外副作用——只是让另一个本来没变化的 widget 多刷新一次。
    private static let widgetKinds = [DailySummaryConstants.kind, "MailWidget"]

    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/mailwidget-daily-regen.log", isDirectory: false)

    /// 串行化日志写入：readabilityHandler（后台 I/O 队列）和 terminationHandler
    /// 可能在不同队列上触发，用同一个串行队列避免交错写坏文件。
    private static let logQueue = DispatchQueue(label: "com.kris.mailwidget.dailyRegenerator.log")

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    /// widget/宿主查询用：flag 存在且未过期。
    static func isRegenerating(now: Date = Date()) -> Bool {
        guard let startedAt = defaults?.object(forKey: startedAtKey) as? Date else {
            return false
        }
        return now.timeIntervalSince(startedAt) < staleAfter
    }

    /// 按 `DailySourceSettings.selectedSource` 启动一次后台重新生成；立即返回，不阻塞调用方
    /// （`Process.run()` 本身是异步启动，不等待子进程）。
    static func regenerate() {
        // 防连点重入：已经有一次在跑（且未过期）就什么都不做。
        guard !isRegenerating() else { return }

        defaults?.set(Date(), forKey: startedAtKey)
        reloadWidgets()

        let source = DailySourceSettings.selectedSource
        guard let resolvedCLI = cli(for: source) else {
            log("未知日报源 \(source)，跳过重新生成。")
            finishEarly()
            return
        }

        guard let cliPath = AgentCLILocator.path(for: resolvedCLI),
              FileManager.default.isExecutableFile(atPath: cliPath) else {
            log("未找到 \(resolvedCLI.rawValue) 命令行，请在设置里指定路径（来源 \(source)）")
            finishEarly()
            return
        }
        let executableURL = URL(fileURLWithPath: cliPath)

        let prompt = DailySummaryPromptTemplate.render(for: source)
        let unresolved = DailySummaryPromptTemplate.unresolvedPlaceholders(in: prompt)
        guard unresolved.isEmpty else {
            log("提示词仍有未解析占位符 \(unresolved.map(\.rawValue).joined(separator: "、"))，跳过本次重新生成（多半是日报邮箱尚未配置）")
            finishEarly()
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments(for: source, prompt: prompt)
        // GUI app（LSUIElement）继承到的 PATH 很窄，通常只有 /usr/bin:/bin:/usr/sbin:/sbin。
        // codex 是 `#!/usr/bin/env node` 脚本，env 要能找到 node 才能起来；显式把
        // Homebrew 的 bin 目录补进 PATH，不依赖调用环境本身有没有带上。
        process.environment = expandedEnvironment()
        // 工作目录不能是继承来的、不可预期的值（宿主 app 的 cwd 不是 git 仓库）——
        // 明确钉在 home 目录，行为可预期，也是 codex 的"不在受信目录"判定所依赖的路径。
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // 真机首跑实测 codex 会等额外的 stdin 输入（继承了打开的管道就会挂起/误读）；
        // 两个来源都不需要 stdin，显式置空杜绝这类悬挂。
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            appendProcessOutput(data)
        }

        process.terminationHandler = { finishedProcess in
            pipe.fileHandleForReading.readabilityHandler = nil
            log("日报重新生成进程结束（来源 \(source)，退出码 \(finishedProcess.terminationStatus)）")
            finishEarly()
        }

        do {
            try process.run()
            log("已启动日报重新生成（来源 \(source)）")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            log("启动失败（来源 \(source)）：\(error.localizedDescription)")
            finishEarly()
        }
    }

    // MARK: - 按来源分发

    /// 来源字符串 → CLI 种类。只有 codex/claude 两个内置来源有对应的可执行文件；
    /// 其它来源（用户接入的任意 agent）走 `installLaunchAgent` 的独立命令模板，
    /// 不经过这里，所以未知来源返回 nil 是"没有对应 CLI"而不是"CLI 没装"——
    /// 调用方据此分别给出"未知来源"和"未找到命令行"两种不同的日志文案。
    private static func cli(for source: String) -> AgentCLI? {
        switch source {
        case DailySource.codex:
            return .codex
        case DailySource.claude:
            return .claude
        default:
            return nil
        }
    }

    private static func arguments(for source: String, prompt: String) -> [String] {
        switch source {
        case DailySource.codex:
            // `codex exec --help` 确认 PROMPT 是位置参数（未提供或传 `-` 才会退回 stdin）。
            // `--skip-git-repo-check`：宿主 app 的工作目录不是 git 仓库，codex 默认的
            // 受信目录检查会直接拒绝执行（真机首跑实测命中）；这是官方给非仓库场景的出口。
            return ["exec", "--skip-git-repo-check", prompt]
        default:
            // Claude：`claude -p <prompt>`。
            return ["-p", prompt]
        }
    }

    private static func expandedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existingPaths = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var merged: [String] = []
        for path in extraPaths + existingPaths where !merged.contains(path) {
            merged.append(path)
        }
        environment["PATH"] = merged.joined(separator: ":")
        return environment
    }

    // MARK: - 收尾

    /// 清 flag + 再 reload 一次。用于三种"没有真正开始等待 ingest"的早退路径
    /// （未知来源、可执行文件缺失、启动失败）以及 terminationHandler 的异常兜底——
    /// 都不该让 widget 卡在"重新生成中"直到 15 分钟过期。
    private static func finishEarly() {
        defaults?.removeObject(forKey: startedAtKey)
        reloadWidgets()
    }

    private static func reloadWidgets() {
        for kind in widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }

    // MARK: - 日志

    private static func log(_ message: String) {
        appendToLog("\(message)\n")
    }

    private static func appendProcessOutput(_ data: Data) {
        appendToLog(String(decoding: data, as: UTF8.self))
    }

    /// 行首加时间戳后追加写日志文件。子进程一次读到的 chunk 可能含多行，
    /// 这里按行拆分逐行加戳；这是一份诊断日志，不追求跨 chunk 的字节级行缓冲。
    private static func appendToLog(_ text: String) {
        guard !text.isEmpty else { return }
        logQueue.async {
            let timestamp = logTimestampFormatter.string(from: Date())
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var stamped = ""
            for (index, line) in lines.enumerated() {
                // 末尾因为文本以 \n 结尾而产生的空字符串不算一行，跳过。
                if index == lines.count - 1 && line.isEmpty { continue }
                stamped += "[\(timestamp)] \(line)\n"
            }
            guard let data = stamped.data(using: .utf8), !data.isEmpty else { return }
            appendData(data, to: logURL)
        }
    }

    /// 每次都开关一次 FileHandle 而不是长持一个句柄：写入频率低（一天几次人工点击），
    /// 换来的是不用操心跨进程生命周期维护句柄。
    private static func appendData(_ data: Data, to url: URL) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } catch {
            // 日志本身写失败没有更好的兜底位置了；静默丢弃，不影响重新生成主流程。
        }
    }
}
