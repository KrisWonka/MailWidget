// DailySourceInstaller.swift
// 把日报定时任务装到各家 agent 里（设计文档 §9）。
//
// 每个出口都是**一次性写入**：写完就撒手，App 不做持续托管、不轮询、不自动启停。
// 这样 App 不会变成别人配置文件的常驻写入方，出错面小得多。
//
// 四个出口全部从 DailySummaryPromptTemplate 渲染，所以无论走哪条路，agent 拿到的
// 指令和路径完全一致。

import AppKit
import Foundation

enum DailySourceInstaller {

    enum InstallError: LocalizedError {
        case unresolvedPlaceholders([String])
        case claudeExecutableNotFound
        case codexExecutableNotFound
        case commandTemplateMissingPromptToken
        case writeFailed(String, underlying: Error)
        case launchctlFailed(String)
        case codexAutomationUnreadable(String)

        var errorDescription: String? {
            switch self {
            case let .unresolvedPlaceholders(names):
                return "模板仍有未替换的占位符：\(names.joined(separator: "、"))"
            case .claudeExecutableNotFound:
                return "找不到 claude 可执行文件。请先安装 Claude Code，或改用「为其它 CLI agent 生成定时任务」并手填命令。"
            case .codexExecutableNotFound:
                return "找不到 codex 可执行文件。请先安装 Codex CLI，或改用「为其它 CLI agent 生成定时任务」并手填命令。"
            case .commandTemplateMissingPromptToken:
                return "启动命令里必须包含 {PROMPT_FILE}，否则 agent 拿不到提示词。"
            case let .writeFailed(path, underlying):
                return "写入失败：\(path)（\(underlying.localizedDescription)）"
            case let .launchctlFailed(detail):
                return "launchctl 装载失败：\(detail)"
            case let .codexAutomationUnreadable(path):
                return "无法读取 Codex 任务配置：\(path)"
            }
        }
    }

    struct Outcome {
        let summary: String
        let writtenPaths: [String]
    }

    // MARK: - 公共基础

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    private static func renderedPrompt(for sourceID: String) throws -> String {
        let prompt = DailySummaryPromptTemplate.render(for: sourceID)
        let leftovers = DailySummaryPromptTemplate.unresolvedPlaceholders(in: prompt)
        guard leftovers.isEmpty else {
            throw InstallError.unresolvedPlaceholders(leftovers.map(\.rawValue))
        }
        return prompt
    }

    /// Not `private` — contract 12's `MailSummaryAutomationInstaller` reuses this
    /// (and `run`/`backup`/`runnerScript`/`launchAgentPlist` below) instead of
    /// keeping a second copy of "write a file" / "shell out to launchctl" / "the
    /// 3-retry runner script" / "the launchd plist XML".
    static func write(_ text: String, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw InstallError.writeFailed(url.path, underlying: error)
        }
    }

    /// 覆盖别人的配置文件前先留一份带时间戳的备份。日报的增量游标一旦丢失就会
    /// 造成邮件重复或漏报，备份是唯一的后悔药。
    static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter.backupStamp.string(from: Date())
        let target = url.appendingPathExtension("bak.\(stamp)")
        do {
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            throw InstallError.writeFailed(target.path, underlying: error)
        }
    }

    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - 出口 1：Codex

    static var existingCodexAutomationURL: URL? {
        let candidate = home.appendingPathComponent(".codex/automations/daily-gmail-summary/automation.toml")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// 已存在 `daily-gmail-summary` 时**不新建、不覆盖**——它持有历史增量游标。
    /// 只把 prompt 里的 ingest 命令替换成当前这个 app 的路径，其余一字不动。
    static func updateExistingCodexAutomation() throws -> Outcome {
        guard let url = existingCodexAutomationURL else {
            throw InstallError.codexAutomationUnreadable(
                home.appendingPathComponent(".codex/automations/daily-gmail-summary/automation.toml").path
            )
        }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            throw InstallError.codexAutomationUnreadable(url.path)
        }

        try backup(url)

        // TOML 里的引号是转义过的，替换时要按转义形态匹配。
        let command = DailySummaryPromptTemplate
            .ingestCommand(for: DailySource.codex)
            .replacingOccurrences(of: "\"", with: "\\\"")

        guard let range = text.range(
            of: #"[^`]*--ingest [^`]*--source codex"#,
            options: .regularExpression
        ) else {
            throw InstallError.codexAutomationUnreadable(url.path)
        }
        text.replaceSubrange(range, with: command)
        try write(text, to: url)

        return Outcome(
            summary: "已更新现有 Codex 任务的 ingest 路径（历史增量游标保持不变）",
            writtenPaths: [url.path]
        )
    }

    // MARK: - 升级时刷新已装任务的提示词

    /// 把磁盘上每一份 `prompt-<source>.md` 按当前模板重新渲染一遍。启动时调用一次。
    ///
    /// 2026-09-15 第二台机器实录暴露的问题：提示词是**装定时任务那一刻**写进
    /// `prompt-<source>.md` 的，之后 app 再怎么升级都不会碰它。于是这几天改进模板的所有
    /// 修复——时区跟随本机、零邮件不覆盖当天日报、游标换到可写目录——对**已经装好定时
    /// 任务的机器一次都没生效过**，除非用户恰好又去点了一次「一键添加」。而那台机器上
    /// 的日报正是由 9:00 的 launchd 任务产出的，用的一直是几天前那份旧提示词。
    ///
    /// 只重写真正需要重写的：渲染结果与磁盘内容一致就不动（避免每次启动都写盘）。
    ///
    /// **不渲染出占位符就不写**：`render` 在日报邮箱还没配置时会留下
    /// `<<MAILBOX_NOT_CONFIGURED>>`，那种半成品绝不能覆盖掉一份原本好好的提示词——
    /// 宁可保留旧的，也不要把定时任务喂成废的。
    /// 启动时把已装任务的**全部生成物**对齐到当前代码：提示词 + runner 脚本。
    ///
    /// 两者都是"装任务那一刻"写死进磁盘的，app 升级都不会碰。只修提示词是不够的——
    /// runner 脚本里同样住着会随代码演进的东西（PATH 注入、`cd "$HOME"`、看门狗、
    /// 兜底发布、关 stdin），这些修复同样到不了已装好的机器。
    static func refreshInstalledArtifacts() {
        DailySummaryPublisher.seedPublishedMirrorIfNeeded()
        refreshInstalledPrompts()
        refreshInstalledRunnerScripts()
        refreshInstalledSchedules()
    }

    /// 按当前时间表重写已装日报任务的 launchd plist，并重新装载。
    ///
    /// 同一类"生成物冻结在磁盘上"的问题：plist 也是装任务那一刻写死的。不刷新它，
    /// 2026-09-19 把一天一次改成一天三次这个修复，对已经装好任务的机器就永远不生效。
    ///
    /// **只在内容确实变了时才 bootout/bootstrap**——重新装载 launchd 任务不是免费的，
    /// 不能每次启动都做。只处理 `com.kris.gmaildaily.*`，邮件总结那条任务的时间是用户
    /// 自己在面板里设的，绝不碰。
    private static func refreshInstalledSchedules() {
        let manager = FileManager.default
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        guard let entries = try? manager.contentsOfDirectory(atPath: agents.path) else { return }
        let prefix = "com.kris.gmaildaily."

        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".plist") {
            let label = String(entry.dropLast(".plist".count))
            let sourceID = String(label.dropFirst(prefix.count))
            let scriptURL = DailySummaryConstants.dataDirectoryURL.appendingPathComponent("run-\(sourceID).sh")
            guard manager.fileExists(atPath: scriptURL.path) else { continue }

            let plistURL = agents.appendingPathComponent(entry)
            let logURL = home.appendingPathComponent("Library/Logs/gmail-daily-\(sourceID).log")
            let plist = launchAgentPlist(
                label: label,
                scriptPath: scriptURL.path,
                logPath: logURL.path,
                times: AgentRunPolicy.dailyBriefTimes(for: sourceID)
            )
            if let existing = try? String(contentsOf: plistURL, encoding: .utf8), existing == plist { continue }

            try? backup(plistURL)
            guard (try? write(plist, to: plistURL)) != nil else { continue }
            let domain = "gui/\(getuid())"
            run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        }
    }

    /// 按当前代码重新生成每个已装来源的 `run-<source>.sh`。
    ///
    /// 解析不出 CLI 路径就跳过那个来源——宁可留着旧脚本，也不要写出一个指向空路径的
    /// 废脚本把原本能跑的定时任务弄坏。
    private static func refreshInstalledRunnerScripts() {
        let manager = FileManager.default
        let directory = DailySummaryConstants.dataDirectoryURL
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        for entry in entries where entry.hasPrefix("run-") && entry.hasSuffix(".sh") {
            let sourceID = String(entry.dropFirst("run-".count).dropLast(".sh".count))
            guard let cli = AgentInvocation.cli(for: sourceID),
                  let cliPath = AgentCLILocator.path(for: cli),
                  manager.isExecutableFile(atPath: cliPath) else { continue }

            let promptPath = directory.appendingPathComponent("prompt-\(sourceID).md").path
            guard manager.fileExists(atPath: promptPath) else { continue }

            let script = runnerScript(
                command: AgentInvocation.shellCommand(
                    executablePath: cliPath,
                    source: sourceID,
                    promptFileExpression: "\"\(promptPath)\""
                ),
                executablePath: cliPath,
                markerCommand: dailyRunMarkerCommand,
                fallbackIngest: (
                    payloadPath: directory.appendingPathComponent(
                        DailySummaryConstants.summaryFilename
                    ).path,
                    command: DailySummaryPromptTemplate.ingestCommand(for: sourceID)
                )
            )

            let url = directory.appendingPathComponent(entry)
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == script { continue }
            try? backup(url)
            try? write(script, to: url)
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func refreshInstalledPrompts() {
        let manager = FileManager.default
        let directory = DailySummaryConstants.dataDirectoryURL
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

        for entry in entries where entry.hasPrefix("prompt-") && entry.hasSuffix(".md") {
            let sourceID = String(entry.dropFirst("prompt-".count).dropLast(".md".count))
            guard !sourceID.isEmpty else { continue }

            let rendered = DailySummaryPromptTemplate.render(for: sourceID)
            guard DailySummaryPromptTemplate.unresolvedPlaceholders(in: rendered).isEmpty else { continue }

            let url = directory.appendingPathComponent(entry)
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == rendered { continue }
            try? backup(url)
            try? write(rendered, to: url)
        }
    }

    // MARK: - 出口 1b：Codex（launchd，全新安装）

    /// 给"这台机器上从来没有 `daily-gmail-summary` 历史任务"的场景补一条路径——
    /// 之前这类机器只有 `updateExistingCodexAutomation()` 一条腿，而它硬性要求
    /// `existingCodexAutomationURL != nil`，新机器上按钮永远是灰的，Codex 用户完全
    /// 没有可用出口。这里复用 `installLaunchAgent`（同一套 launchd + 20 分钟看门狗 +
    /// 兜底 ingest 的 runner 脚本），跟 `installClaudeJob` 是同一形态，只是命令换成
    /// `codex exec`。
    ///
    /// 命令形态照抄 `DailyRegenerator.arguments(for:prompt:)` 里已经在真机跑通的
    /// 组合：`codex exec --help` 确认 PROMPT 是位置参数；`--skip-git-repo-check`
    /// 是必需的——launchd 的工作目录不是 git 仓库，codex 默认的受信目录检查会直接
    /// 拒绝执行（真机首跑实测命中过这个坑，`DailyRegenerator.swift:93-94` 同一注释）。
    ///
    /// 时间默认 09:00：日报另外两条路径分别是 Claude 09:07、邮件总结 08:50，
    /// 三者故意错开，避免同时抢 launchd 或撞见彼此的日志。
    static func installCodexJob() throws -> Outcome {
        guard let codex = AgentCLILocator.path(for: .codex) else {
            throw InstallError.codexExecutableNotFound
        }
        return try installLaunchAgent(
            sourceID: DailySource.codex,
            commandTemplate: AgentInvocation.shellCommand(
                executablePath: codex,
                source: DailySource.codex,
                promptFileExpression: "{PROMPT_FILE}"
            ),
            executablePath: codex,
        )
    }

    // MARK: - 出口 2：Claude（launchd）

    /// `--permission-mode auto`：让 headless 运行时的每次工具权限询问都交给模型分类器
    /// 就地批准/拒绝，而不是等一个不存在的人来点「允许」——这正是 2026-08-25 那次
    /// launchd 任务卡住近 3 小时（09:23 启动、12:17 才结束）的根因，日志里 agent 自己
    /// 也留言指出"没带任何权限相关参数，可能在权限询问上静默卡住"。
    ///
    /// 特意不用 `--allowedTools`：跑 `claude --help` 实测它是**白名单**语义——
    /// "Comma or space-separated list of tool names to allow"——只列 Bash/Read/Write/
    /// Edit/Glob/Grep 会把没在名单里的 Gmail MCP 连接器工具一并挡掉，日报任务的核心
    /// 步骤（读 Gmail）反而跑不了。`claude -p --permission-mode bogus` 报出的合法取值
    /// 及其官方说明（从 CLI 内嵌文本核实）：
    ///   'default' - Standard behavior, prompts for dangerous operations.
    ///   'acceptEdits' - Auto-accept file edit operations.
    ///   'bypassPermissions' - Bypass all permission checks (requires allowDangerouslySkipPermissions).
    ///   'plan' - Planning mode, no actual tool execution.
    ///   'dontAsk' - Don't prompt for permissions, deny if not pre-approved.
    ///   'auto' - Use a model classifier to approve/deny permission prompts.
    /// 'default' 就是现在卡住的那个模式；'dontAsk' 会静默拒绝一切没有预先批准的工具
    /// （包括 MCP），等于把任务变成"跑完但什么也没做"；'bypassPermissions' 虽然同样
    /// 不会卡住、也不缩小工具范围，但需要额外的 `allowDangerouslySkipPermissions`
    /// 开关且对一个无人看管、每天自动执行的任务放开"全部跳过"偏激进。'auto' 是唯一
    /// 既不缩小工具集、又保证不会再阻塞等待人工输入的选项，所以选它。
    static func installClaudeJob() throws -> Outcome {
        guard let claude = AgentCLILocator.path(for: .claude) else {
            throw InstallError.claudeExecutableNotFound
        }
        return try installLaunchAgent(
            sourceID: DailySource.claude,
            commandTemplate: AgentInvocation.shellCommand(
                executablePath: claude,
                source: DailySource.claude,
                promptFileExpression: "{PROMPT_FILE}"
            ),
            executablePath: claude,
        )
    }

    // MARK: - 出口 3：任意 CLI agent（launchd）

    /// `commandTemplate` 里 `{PROMPT_FILE}` 会被替换成渲染好的提示词文件路径，
    /// 例如 `gemini -p {PROMPT_FILE}`。
    static func installLaunchAgent(
        sourceID: String,
        commandTemplate: String,
        executablePath: String? = nil
    ) throws -> Outcome {
        let times = AgentRunPolicy.dailyBriefTimes(for: sourceID)
        guard commandTemplate.contains("{PROMPT_FILE}") else {
            throw InstallError.commandTemplateMissingPromptToken
        }

        let prompt = try renderedPrompt(for: sourceID)
        let dataDir = DailySummaryConstants.dataDirectoryURL
        let promptURL = dataDir.appendingPathComponent("prompt-\(sourceID).md")
        let scriptURL = dataDir.appendingPathComponent("run-\(sourceID).sh")
        let logURL = home.appendingPathComponent("Library/Logs/gmail-daily-\(sourceID).log")
        let label = "com.kris.gmaildaily.\(sourceID)"
        let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

        try write(prompt, to: promptURL)
        try write(
            runnerScript(
                command: commandTemplate.replacingOccurrences(
                    of: "{PROMPT_FILE}",
                    with: "\"\(promptURL.path)\""
                ),
                executablePath: executablePath,
                markerCommand: dailyRunMarkerCommand,
                fallbackIngest: (
                    payloadPath: dataDir.appendingPathComponent(
                        DailySummaryConstants.summaryFilename
                    ).path,
                    command: DailySummaryPromptTemplate.ingestCommand(for: sourceID)
                )
            ),
            to: scriptURL
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try backup(plistURL)
        try write(
            launchAgentPlist(label: label, scriptPath: scriptURL.path, logPath: logURL.path,
                             times: times),
            to: plistURL
        )

        let domain = "gui/\(getuid())"
        run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let bootstrap = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        guard bootstrap.status == 0 else {
            throw InstallError.launchctlFailed(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let check = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard check.status == 0 else {
            throw InstallError.launchctlFailed("装载后 launchctl print 查不到 \(label)")
        }

        DailySourceSettings.registerSource(sourceID)

        return Outcome(
            summary: "已装载 \(label)，每天 "
                + times.map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: "、")
                + " 运行",
            writtenPaths: [promptURL.path, scriptURL.path, plistURL.path]
        )
    }

    /// 生成实现挪进了 DataKit 的 `LaunchAgentRunnerScript`——这段脚本在真机上连续藏过
    /// 三个 bug（PATH 缺失导致 `env: node` 找不到、工作目录为 `/` 让 codex 降级成只读沙箱、
    /// 兜底发布被锁在退出码 0 的分支里），而它在 app target 里根本没法单测。搬进 DataKit
    /// 后可以直接用 `bash -n` 校验语法并断言关键行。这里保留同名转发，调用点不变。
    static func runnerScript(
        command: String,
        executablePath: String? = nil,
        markerCommand: String? = nil,
        fallbackIngest: (payloadPath: String, command: String)? = nil
    ) -> String {
        LaunchAgentRunnerScript.make(
            command: command,
            executablePath: executablePath,
            markerCommand: markerCommand,
            fallbackIngest: fallbackIngest
        )
    }

    /// `MailWidget --daily-run` 的完整命令前缀，脚本用它标记生成中。
    static var dailyRunMarkerCommand: String {
        "\"\(DailySummaryPromptTemplate.hostExecutableURL.path)\" --daily-run"
    }

    /// 单个时间点的旧签名，邮件总结那条任务还在用。
    static func launchAgentPlist(
        label: String, scriptPath: String, logPath: String, hour: Int, minute: Int
    ) -> String {
        launchAgentPlist(label: label, scriptPath: scriptPath, logPath: logPath, times: [(hour, minute)])
    }

    /// `StartCalendarInterval` 接受一个 dict 的数组，每个元素一个触发时刻。
    static func launchAgentPlist(
        label: String, scriptPath: String, logPath: String, times: [(hour: Int, minute: Int)]
    ) -> String {
        let intervals = times.map { time in
            """
                    <dict>
                        <key>Hour</key><integer>\(time.hour)</integer>
                        <key>Minute</key><integer>\(time.minute)</integer>
                    </dict>
            """
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/bash</string>
                <string>\(scriptPath)</string>
            </array>
            <key>StartCalendarInterval</key>
            <array>
        \(intervals)
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    // MARK: - 出口 4：复制 / 导出模板

    @discardableResult
    static func copyPromptToPasteboard(sourceID: String) throws -> Outcome {
        let prompt = try renderedPrompt(for: sourceID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        return Outcome(summary: "提示词已复制到剪贴板（占位符已替换为真实路径）", writtenPaths: [])
    }

    static func exportTemplate(sourceID: String, to directory: URL) throws -> Outcome {
        let prompt = try renderedPrompt(for: sourceID)
        let bundle = directory.appendingPathComponent("gmail-daily-template", isDirectory: true)

        try write(prompt, to: bundle.appendingPathComponent("prompt.md"))
        try write(contractDocument(sourceID: sourceID), to: bundle.appendingPathComponent("CONTRACT.md"))
        try write(jsonSchema, to: bundle.appendingPathComponent("schema.json"))

        return Outcome(
            summary: "模板已导出到 \(bundle.path)",
            writtenPaths: ["prompt.md", "CONTRACT.md", "schema.json"].map {
                bundle.appendingPathComponent($0).path
            }
        )
    }

    private static func contractDocument(sourceID: String) -> String {
        """
        # Gmail 日报生产者契约 v1

        任何 agent 只要满足下面的前提、并完成三步契约，就能成为 MailWidget 的日报来源。

        ## 适配前提

        | 能力 | 必需原因 | 谁提供 |
        |---|---|---|
        | 读取 Gmail | 抓取邮件 | **agent 自身，硬门槛** |
        | 执行本地 shell 命令 | 调用 ingest | **agent 自身，硬门槛** |
        | 被定时触发 | 每天运行 | agent 自带，或用 launchd 补齐 |
        | 持久化少量状态 | 增量游标 | agent 自带，或用下面的游标文件补齐 |

        读不了 Gmail 的 agent 接不了，没有变通办法。

        ## 三步契约

        1. 原子写 UTF-8 JSON 到 `\(DailySummaryConstants.dataDirectoryURL.path)/\(DailySummaryConstants.summaryFilename)`
           （先写同目录临时文件，完全关闭，再 rename 覆盖）
        2. 执行 `\(DailySummaryPromptTemplate.ingestCommand(for: sourceID))`
        3. 把增量游标写入 `\(DailySummaryPromptTemplate.cursorPath(for: sourceID))`

        ## ingest 退出码

        | 码 | 含义 |
        |---|---|
        | 0 | 已发布 |
        | 1 | 载荷校验失败，上一份日报保持不变 |
        | 2 | 命令行参数错误 |
        | 3 | 本来源当前未被选中，未发布（不是错误） |

        ## 失败语义

        账号不匹配、连接器失败或抓取不完整时：**不要**覆盖载荷、**不要**调用 ingest、
        **不要**推进游标。保留上一份已验证的发布。

        校验失败绝不会破坏已有日报——ingest 先校验后落盘，所以接错了也弄不坏当前显示的内容。

        ## 载荷结构

        见同目录 `schema.json`，提示词全文见 `prompt.md`。
        """
    }

    /// 导出的 JSON Schema 里，`gmailURL` 字段要求精确匹配"当前配置邮箱"的
    /// Gmail 链接。原来这段正则是硬编码的个人邮箱字面量；去个人化后必须跟着
    /// `DailySummaryConstants.expectedMailbox`走，不能留一个换了邮箱也不会变的
    /// 死值。这里的转义是两层的：Swift 源码里的 `\\` 先被解成一个字面反斜杠，
    /// 写进导出的 JSON 文本后又要被 JSON 的转义规则再解一层，JSON 解析完才是
    /// 真正喂给正则引擎的那个反斜杠——所以要一个字面反斜杠，源码里得写 `\\\\`。
    /// "@" 换成 "%40"，因为 Gmail 的 `authuser` 查询参数里 "@" 是这样被
    /// percent-encode 的（`DailySummaryValidator.validateGmailURL` 校验的正是
    /// 这个形态）。
    private static var gmailURLPatternMailboxSegment: String {
        let percentEncoded = DailySummaryConstants.expectedMailbox.replacingOccurrences(of: "@", with: "%40")
        return percentEncoded.replacingOccurrences(of: ".", with: "\\\\.")
    }

    private static var jsonSchema: String {
        """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "Gmail 日报载荷 (schemaVersion 1)",
      "type": "object",
      "required": ["schemaVersion", "mailbox", "generatedAt", "headline", "items"],
      "additionalProperties": false,
      "properties": {
        "schemaVersion": { "const": 1 },
        "mailbox": { "const": "\(DailySummaryConstants.expectedMailbox)" },
        "generatedAt": {
          "type": "string",
          "description": "RFC 3339，带 \(DailySummaryPromptTemplate.localTimeZoneIdentifier) 的 UTC 偏移"
        },
        "headline": { "type": "string" },
        "items": {
          "type": "array",
          "maxItems": \(DailySummaryConstants.maximumItemCount),
          "items": {
            "type": "object",
            "required": ["id", "level", "title", "detail", "gmailURL"],
            "additionalProperties": false,
            "properties": {
              "id": { "type": "string", "minLength": 1 },
              "level": { "enum": ["immediate", "today", "week", "optional", "info"] },
              "title": { "type": "string", "minLength": 1 },
              "detail": { "type": "string" },
              "gmailURL": {
                "type": "string",
                "pattern": "^https://mail\\\\.google\\\\.com/mail/u/0/\\\\?authuser=\(gmailURLPatternMailboxSegment)#all/.+$"
              },
              "messageIdHeader": {
                "type": "string",
                "minLength": 1,
                "maxLength": 998,
                "pattern": "^[^<>\\\\s]+$",
                "description": "RFC 5322 Message-ID，去掉尖括号。可选；取不到时省略整个键。"
              }
            }
          }
        }
      }
    }
    """
    }
}

private extension ISO8601DateFormatter {
    static let backupStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = .current
        return formatter
    }()
}
