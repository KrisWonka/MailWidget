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
    static func installCodexJob(hour: Int = 9, minute: Int = 0) throws -> Outcome {
        guard let codex = AgentCLILocator.path(for: .codex) else {
            throw InstallError.codexExecutableNotFound
        }
        return try installLaunchAgent(
            sourceID: DailySource.codex,
            commandTemplate: "\"\(codex)\" exec --skip-git-repo-check \"$(cat {PROMPT_FILE})\"",
            hour: hour,
            minute: minute
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
    static func installClaudeJob(hour: Int = 9, minute: Int = 7) throws -> Outcome {
        guard let claude = AgentCLILocator.path(for: .claude) else {
            throw InstallError.claudeExecutableNotFound
        }
        return try installLaunchAgent(
            sourceID: DailySource.claude,
            commandTemplate: "\"\(claude)\" -p --permission-mode auto \"$(cat {PROMPT_FILE})\"",
            hour: hour,
            minute: minute
        )
    }

    // MARK: - 出口 3：任意 CLI agent（launchd）

    /// `commandTemplate` 里 `{PROMPT_FILE}` 会被替换成渲染好的提示词文件路径，
    /// 例如 `gemini -p {PROMPT_FILE}`。
    static func installLaunchAgent(
        sourceID: String,
        commandTemplate: String,
        hour: Int,
        minute: Int
    ) throws -> Outcome {
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
                             hour: hour, minute: minute),
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
            summary: String(format: "已装载 %@，每天 %02d:%02d 运行", label, hour, minute),
            writtenPaths: [promptURL.path, scriptURL.path, plistURL.path]
        )
    }

    /// 重试是为了覆盖 Gmail 连接器 tools fetch 的偶发超时——实测 `claude mcp list`
    /// 连续两次调用就出现过一次超时。无人值守的任务不能因为一次抖动就整天没有日报。
    /// `fallbackIngest` 是发布环节的兜底：agent 在 headless 模式下**可能拿不到执行
    /// 命令的权限**，却仍在自己的输出里声称"ingest 退出码 0，已发布"（2026-08-25 实录：
    /// staging 载荷写到了 13:23，App Group 却停在前一天，游标还自报 published）。
    /// 脚本自己跑一遍 ingest 不经过任何权限系统，是确定性的；只在 staging 载荷确实是
    /// 本次运行刚写的（20 分钟内）时才执行，避免把陈旧载荷盖到更新的发布上。
    ///
    /// 每次尝试都包了一层 20 分钟（1200s）看门狗，直接对应 2026-08-25 那次实录
    /// （09:23 启动、12:17 才结束，近 3 小时）——`--permission-mode auto`（见
    /// `installClaudeJob`）已经从源头堵死"等一个不存在的人点允许"这条卡死路径，这层
    /// 超时是第二道保险：万一还有别的原因卡住（网络挂起、MCP 连接器无响应等），也不能
    /// 让单次尝试吃掉一整个白天。
    ///
    /// 选择"后台 PID + kill"而不是 `perl -e 'alarm shift; exec @ARGV'`：macOS 没有
    /// `/usr/bin/timeout`（已用 `ls` 实测确认不存在），perl 版能杀掉被 exec 替换的那
    /// 一个进程，但 `claude -p` 会在权限询问、Bash 工具调用等场景 fork 出子进程——
    /// `alarm`+`exec` 的 SIGALRM 只送到 exec 出来的那一个进程，杀不到它自己再 fork
    /// 出来的子孙，会留下孤儿进程继续跑。这里改用 `set -m` 开启 job control 让每个
    /// 后台任务拿到独立进程组，超时后 `kill -TERM -- -$pid`（负号 pid = 整个进程组）
    /// 连子孙一起收，5 秒宽限期后 `kill -KILL` 兜底。已用两个最小复现脚本验证过：
    /// (1) `sleep 10` 在 3 秒超时下确实提前终止、返回非零状态，脚本据此判定失败并进入
    /// 重试；(2) 故意 fork 一个孙进程验证它也被杀死，不是只砍了直接子进程。
    static func runnerScript(command: String, fallbackIngest: (payloadPath: String, command: String)? = nil) -> String {
        let ingestBlock = fallbackIngest.map { ingest in
            """

              if [ -f "\(ingest.payloadPath)" ]; then
                payload_age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f %m "\(ingest.payloadPath)") ))
                if [ "$payload_age" -lt 1200 ]; then
                  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] 兜底发布（载荷 ${payload_age}s 前写入）"
                  \(ingest.command) || echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] 兜底发布失败"
                else
                  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] 跳过兜底发布：载荷是 ${payload_age}s 前的旧件"
                fi
              fi
            """
        } ?? ""

        return """
        #!/bin/bash
        # 由 MailWidget 生成。手工改动会在下次"一键添加"时被覆盖（改动前会自动备份）。
        set -uo pipefail
        # 开 job control：让下面每个 `( ... ) &` 后台任务拿到独立进程组，超时时才能用
        # `kill -TERM -- -$pid` 把它和它 fork 出来的子孙一并收掉，而不是只砍直接子进程。
        set -m

        for attempt in 1 2 3; do
          echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] attempt ${attempt}/3"

          ( \(command) ) &
          cmd_pid=$!
          (
            /bin/sleep 1200
            if /bin/kill -0 "$cmd_pid" 2>/dev/null; then
              echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] attempt ${attempt}/3 已跑满 20 分钟，判定挂死，终止进程组 -$cmd_pid" >&2
              /bin/kill -TERM -- -"$cmd_pid" 2>/dev/null
              /bin/sleep 5
              /bin/kill -KILL -- -"$cmd_pid" 2>/dev/null
            fi
          ) &
          watchdog_pid=$!

          status=0
          wait "$cmd_pid" || status=$?
          /bin/kill "$watchdog_pid" 2>/dev/null
          wait "$watchdog_pid" 2>/dev/null

          if [ "$status" -eq 0 ]; then
            echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] ok"\(ingestBlock)
            exit 0
          fi
          echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] failed (exit ${status}), retrying in 60s"
          /bin/sleep 60
        done

        echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] giving up after 3 attempts"
        exit 1
        """
    }

    static func launchAgentPlist(
        label: String, scriptPath: String, logPath: String, hour: Int, minute: Int
    ) -> String {
        """
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
            <dict>
                <key>Hour</key><integer>\(hour)</integer>
                <key>Minute</key><integer>\(minute)</integer>
            </dict>
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
          "description": "RFC 3339，带 America/New_York 的 UTC 偏移"
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
