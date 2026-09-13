// DailyRegenerator.swift
// DataKit — 宿主侧「重新生成」执行器：widget 上的按钮触发一次日报重新生成，立即返回不阻塞。
//
// 只负责启动外部 agent 进程（Codex/Claude）并维护一个"进行中"标志；日报本体的落盘、
// --ingest、来源仲裁全部沿用既有链路——`DailySummaryPromptTemplate.render(for:)` 渲染出的
// 提示词里已经包含完整的三步契约（写 latest.json → 调 --ingest → 推进游标，见设计文档 §8）。
// 这里不等待、不解析 agent 是否真的成功发布了新日报：`--ingest` 成功时 App 自己会
// reload；这里的 terminationHandler 只是异常兜底（agent 中途失败、被杀死等），
// 确保"重新生成中"标志和 widget 不会永远卡住。
//
// ⚠️ 真机部署实录（2026-09）：上一段注释里"agent 自己执行 --ingest"这个假设并不总是
// 成立——朋友机器上 codex 把 latest.json 写到了交接目录，却从没执行 --ingest，
// App Group 里没有日报、widget 一直是空的，agent 却报告成功。定时任务那条路
// （`MailWidgetApp/DailySourceInstaller.runnerScript`）早就为这个场景加了 shell 层的
// 兜底发布；手动「重新生成」这条路当时没有同款保险。`terminationHandler` 现在多做
// 一步 `performFallbackPublishIfNeeded`：agent 进程正常结束后，检查交接目录里的
// latest.json 是不是本次运行期间新写的、且比 App Group 里已有的日报新，是的话就由
// 宿主自己完成发布（复用 `DailySummaryPublisher`，与 `--ingest` 走的是同一套步骤）。

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

        // 兜底发布要判定"latest.json 是不是本次运行写的"，必须是这次调用开始时刻，
        // 不是别的时间点（比如 finishEarly 之后才读取的话，早就晚了）。
        let runStartedAt = Date()
        defaults?.set(runStartedAt, forKey: startedAtKey)
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

        // 文件存在 ≠ 能用（真机实录：codex 0.137 文件在，一跑 `exec` 就因为模型版本
        // 不兼容崩溃）。这里比 `AgentCLILocator.isInstalled` 多一步真的探测一次，
        // 不可用就直接跳过，不浪费一次注定失败的进程启动。
        if let reason = AgentCLILocator.unusableReason(for: resolvedCLI) {
            log("\(resolvedCLI.rawValue) 当前不可用，跳过重新生成（来源 \(source)）：\(reason)")
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
        // 常见安装目录补进 PATH，不依赖调用环境本身有没有带上。传 cliPath 是为了连
        // nvm/volta 那种版本化目录里的 node 也能解析出来。
        process.environment = expandedEnvironment(executablePath: cliPath)
        // 工作目录不能是继承来的、不可预期的值（宿主 app 的 cwd 不是 git 仓库）——
        // 明确钉在 home 目录，行为可预期，也是 codex 的"不在受信目录"判定所依赖的路径。
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // 真机首跑实测 codex 会等额外的 stdin 输入（继承了打开的管道就会挂起/误读）；
        // 两个来源都不需要 stdin，显式置空杜绝这类悬挂。
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // agent 的 stdout/stderr 不再实时逐块落盘——真机实录：agent 会把自己的 system
        // prompt（几十 KB 设计规范文本）也吐到输出里，混进日志后真正的状态行被淹没，
        // 排查时几乎没法看。改成攒进 `TruncatingLogBuffer`（只保留头尾各 4KB），进程结束
        // 时一次性落盘；我们自己打的状态行（`log(_:)`）完全不走这条路，始终原样完整写入。
        let outputBuffer = TruncatingLogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBuffer.append(data)
        }

        process.terminationHandler = { finishedProcess in
            pipe.fileHandleForReading.readabilityHandler = nil
            let renderedOutput = outputBuffer.render()
            if !renderedOutput.isEmpty {
                appendProcessOutput(renderedOutput)
            }
            log("日报重新生成进程结束（来源 \(source)，退出码 \(finishedProcess.terminationStatus)）")
            performFallbackPublishIfNeeded(source: source, runStartedAt: runStartedAt)
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

    // MARK: - 兜底发布（agent 跑完了但没执行 --ingest）

    /// 兜底发布该不该真的执行——纯判定，不碰文件系统/App Group，方便单测直接喂值。
    enum FallbackPublishDecision: Equatable {
        case publish
        /// `reason` 是给日志看的中文说明，不是错误。
        case skip(reason: String)
    }

    /// - Parameters:
    ///   - stagingModifiedAt: 交接目录 `latest.json` 的文件修改时间；文件不存在传 nil。
    ///   - runStartedAt: 本次 `regenerate()` 调用开始的时间。
    ///   - stagingGeneratedAt: 交接目录载荷里 `generatedAt` 字段解析出的时间；解析不出
    ///     （字段缺失、格式不对）传 nil——这不该挡住发布，真正的格式校验交给
    ///     `DailySummaryPublisher.publish` 的 `DailySummaryCodec.decode`。
    ///   - publishedGeneratedAt: App Group 里已经发布的日报的 `generatedAt`；App Group
    ///     里还没有日报（或读取失败）传 nil。
    static func fallbackPublishDecision(
        stagingModifiedAt: Date?,
        runStartedAt: Date,
        stagingGeneratedAt: Date?,
        publishedGeneratedAt: Date?
    ) -> FallbackPublishDecision {
        guard let stagingModifiedAt else {
            return .skip(reason: "交接目录里没有 latest.json，agent 大概率没走到写文件那一步")
        }
        guard stagingModifiedAt >= runStartedAt else {
            return .skip(reason: "latest.json 是本次运行开始之前留下的旧文件，跳过兜底发布")
        }
        guard let publishedGeneratedAt else {
            return .publish
        }
        guard let stagingGeneratedAt else {
            // 载荷确实是这次运行写的，只是 generatedAt 解析不出来——不能据此判断新旧，
            // 宁可放行让真正的发布步骤去做完整校验，也不要因为一个次要字段漏发。
            return .publish
        }
        guard stagingGeneratedAt > publishedGeneratedAt else {
            return .skip(reason: "App Group 里已经是不早于这份载荷的日报，agent 大概率已经自己发布过了")
        }
        return .publish
    }

    /// IO 薄层：读交接目录的文件时间 + 解析出的 generatedAt、读 App Group 现有日报的
    /// generatedAt，喂给 `fallbackPublishDecision` 判定，需要发布就调用
    /// `DailySummaryPublisher`（与 `--ingest` 走同一套步骤）。
    ///
    /// 全程只记日志、不抛错——这本身就是异常路径的兜底，兜底再失败也不该让
    /// `regenerate()` 崩掉或把"重新生成中"标志卡住（`finishEarly()` 仍会照常执行）。
    private static func performFallbackPublishIfNeeded(source: String, runStartedAt: Date) {
        let payloadURL = DailySummaryConstants.dataDirectoryURL
            .appendingPathComponent(DailySummaryConstants.summaryFilename, isDirectory: false)

        let stagingModifiedAt = (try? FileManager.default.attributesOfItem(atPath: payloadURL.path))?[.modificationDate] as? Date

        var stagingGeneratedAt: Date?
        if let data = try? Data(contentsOf: payloadURL),
           let staged = try? JSONDecoder().decode(DailySummary.self, from: data) {
            stagingGeneratedAt = staged.generatedDate
        }

        let publishedGeneratedAt = (try? DailySummaryStore().load())?.generatedDate

        let decision = fallbackPublishDecision(
            stagingModifiedAt: stagingModifiedAt,
            runStartedAt: runStartedAt,
            stagingGeneratedAt: stagingGeneratedAt,
            publishedGeneratedAt: publishedGeneratedAt
        )

        switch decision {
        case .skip(let reason):
            log("兜底发布：跳过（\(reason)）")
        case .publish:
            do {
                let summary = try DailySummaryPublisher.publish(payloadURL: payloadURL, source: source)
                log("兜底发布：agent 跑完了但没有（成功）执行 --ingest，宿主自己发布了这次日报（\(summary.items.count) 条，来源 \(source)）")
                reloadWidgets()
            } catch {
                log("兜底发布失败（来源 \(source)）：\(error.localizedDescription)")
            }
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

    /// PATH 的构造挪进 `AgentRuntimePath`，与 `DailySourceInstaller` 生成的 launchd
    /// runner 脚本共用同一份定义——两条路径跑的是同一个 CLI，环境不该有两套说法。
    /// 额外传入可执行文件本身，是为了把 `#!/usr/bin/env node` 这类壳的解释器目录也带上
    /// （见 `AgentRuntimePath.directoriesNeeded(toRun:)` 的真机实录）。
    private static func expandedEnvironment(executablePath: String? = nil) -> [String: String] {
        AgentRuntimePath.expandedEnvironment(
            extraDirectories: executablePath.map(AgentRuntimePath.directoriesNeeded(toRun:)) ?? []
        )
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

/// agent 的 stdout/stderr 只保留头尾各 `headCapacity`/`tailCapacity` 字节——真机实录：
/// agent 会把自己的 system prompt（几十 KB 设计规范文本）也吐到输出里，全量落盘会把
/// 真正有用的状态行淹没。`append(_:)` 在数据到达时增量维护 head/tail，不缓存全量输出，
/// 内存占用恒定（≤ head+tail 容量），不会因为 agent 输出量大而失控增长。
///
/// `readabilityHandler` 的回调线程和 `terminationHandler` 的回调线程不保证是同一个，
/// 内部用一把锁保护 head/tail/totalBytes，`append`/`render` 都可以安全地跨线程调用。
final class TruncatingLogBuffer {
    private let headCapacity: Int
    private let tailCapacity: Int
    private let lock = NSLock()
    private var head = Data()
    private var tail = Data()
    private var totalBytes = 0

    init(headCapacity: Int = 4096, tailCapacity: Int = 4096) {
        self.headCapacity = headCapacity
        self.tailCapacity = tailCapacity
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        totalBytes += data.count
        if head.count < headCapacity {
            head.append(data.prefix(headCapacity - head.count))
        }
        tail.append(data)
        if tail.count > tailCapacity {
            tail.removeFirst(tail.count - tailCapacity)
        }
    }

    /// 重建最终要落盘的字节序列：
    /// - 总量没超过 head+tail 容量时精确复原原始内容（不重复、不丢字节）——head 和 tail
    ///   在这种量级下的窗口会重叠，直接拼接会把重叠区间打印两遍，所以要从 tail 里裁掉
    ///   已经在 head 里出现过的那一段。
    /// - 超过容量才是真正的截断：head + "…[省略 N 字节]…" + tail。
    func render() -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard totalBytes > headCapacity + tailCapacity else {
            guard totalBytes > headCapacity else { return head }
            // total 落在 (headCapacity, headCapacity + tailCapacity] 之间：tail 已经攒满
            // tailCapacity 字节，其中前 (headCapacity + tailCapacity - totalBytes) 字节
            // 与 head 的尾部重叠，丢掉那一段再拼接。
            let overlap = headCapacity + tailCapacity - totalBytes
            return head + tail.dropFirst(overlap)
        }

        let omitted = totalBytes - headCapacity - tailCapacity
        let marker = "\n…[省略 \(omitted) 字节]…\n".data(using: .utf8) ?? Data()
        return head + marker + tail
    }
}
