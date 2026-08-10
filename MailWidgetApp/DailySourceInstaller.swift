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

    // MARK: - 出口 2：Claude（launchd）

    private static let claudeCandidatePaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    static var discoveredClaudePath: String? {
        claudeCandidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func installClaudeJob(hour: Int = 9, minute: Int = 7) throws -> Outcome {
        guard let claude = discoveredClaudePath else {
            throw InstallError.claudeExecutableNotFound
        }
        return try installLaunchAgent(
            sourceID: DailySource.claude,
            commandTemplate: "\"\(claude)\" -p \"$(cat {PROMPT_FILE})\"",
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
            runnerScript(command: commandTemplate.replacingOccurrences(
                of: "{PROMPT_FILE}",
                with: "\"\(promptURL.path)\""
            )),
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
    static func runnerScript(command: String) -> String {
        """
        #!/bin/bash
        # 由 MailWidget 生成。手工改动会在下次"一键添加"时被覆盖（改动前会自动备份）。
        set -uo pipefail

        for attempt in 1 2 3; do
          echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] attempt ${attempt}/3"
          if \(command); then
            echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] ok"
            exit 0
          fi
          echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] failed, retrying in 60s"
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

    private static let jsonSchema = """
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
                "pattern": "^https://mail\\\\.google\\\\.com/mail/u/0/\\\\?authuser=krisxia%40umich\\\\.edu#all/.+$"
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

private extension ISO8601DateFormatter {
    static let backupStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = .current
        return formatter
    }()
}
