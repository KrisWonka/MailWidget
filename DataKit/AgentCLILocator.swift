// AgentCLILocator.swift
// DataKit — 定位 claude / codex 命令行可执行文件的路径。
//
// 去个人化背景：`MailSummarizer` 和 `DailyRegenerator` 曾经把 claude/codex 的可执行
// 文件路径写死为原作者本机的具体位置（`/Users/kris/.local/bin/claude`、
// `/opt/homebrew/bin/codex`）。别人克隆仓库后，这两个 CLI 十有八九不在同样的路径上，
// 于是日报生成/邮件总结全部静默失败。这里统一探测逻辑，两处调用方都改成问它。
//
// 探测顺序（依次尝试，找到第一个就返回）：
// 1. 用户在设置里手填的覆盖路径（App Group 键 `cliPath.<claude|codex>`）——这是
//    最高优先级，用户明确指定了就不应该再猜。
// 2. 已缓存的上一次探测结果（App Group 键 `cliPath.discovered.<claude|codex>`）——
//    避免每次调用都重新扫描候选路径 / fork 一次登录 shell。缓存值用前会重新验证
//    "文件还在且可执行"，失效了就当没有，继续往下探测，不会用一个过期缓存卡死。
// 3. 常见安装位置候选列表（`~/.local/bin/`、`/opt/homebrew/bin/`、`/usr/local/bin/`，
//    claude 额外加 `~/.claude/local/`）。
// 4. 登录 shell 的 `command -v <name>`——GUI app（LSUIElement）继承到的 PATH 很窄
//    （通常只有 `/usr/bin:/bin:/usr/sbin:/sbin`），直接 `which` 当前进程的 PATH
//    十有八九扑空；`/bin/zsh -lc` 会加载用户的 `.zshrc`/`.zprofile`，PATH 更接近
//    用户在终端里能看到的那份。
//
// 全部失败则返回 nil，代表"这台机器上没装"。

import Foundation

enum AgentCLI: String {
    case claude
    case codex
}

enum AgentCLILocator {

    // MARK: - 对外 API

    /// 依次尝试：覆盖路径 → 缓存 → 常见安装位置 → 登录 shell 的 which。
    /// 找到即缓存进 App Group 键，返回 nil 表示未安装。
    static func path(for cli: AgentCLI) -> String? {
        if let overridden = overridePath(for: cli) {
            return overridden
        }
        if let cached = cachedPath(for: cli), FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }
        if let found = candidatePaths(for: cli).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            cache(found, for: cli)
            return found
        }
        if let viaWhich = whichPath(for: cli) {
            cache(viaWhich, for: cli)
            return viaWhich
        }
        return nil
    }

    /// 用户在设置里手动指定路径；传 nil 或空字符串清除覆盖，回落到自动探测。
    static func setOverride(_ path: String?, for cli: AgentCLI) {
        guard let path, !path.isEmpty else {
            defaults?.removeObject(forKey: overrideKey(for: cli))
            return
        }
        defaults?.set(path, forKey: overrideKey(for: cli))
    }

    /// `path(for:)` 解析出的路径确实是一个可执行文件。覆盖路径写错了、或缓存的旧路径
    /// 对应的文件已被删除/重装到别处时，这里如实返回 false——不代表 `path(for:)`
    /// 会返回 nil（它仍然把解析到的字符串原样交给调用方，让调用方能报出"路径是这个，
    /// 但它不可执行"这种更具体的错误）。
    static func isInstalled(_ cli: AgentCLI) -> Bool {
        guard let resolved = path(for: cli) else { return false }
        return FileManager.default.isExecutableFile(atPath: resolved)
    }

    // MARK: - App Group 键

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    private static func overrideKey(for cli: AgentCLI) -> String {
        "cliPath.\(cli.rawValue)"
    }

    private static func cachedPathKey(for cli: AgentCLI) -> String {
        "cliPath.discovered.\(cli.rawValue)"
    }

    private static func overridePath(for cli: AgentCLI) -> String? {
        guard let value = defaults?.string(forKey: overrideKey(for: cli)), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func cachedPath(for cli: AgentCLI) -> String? {
        guard let value = defaults?.string(forKey: cachedPathKey(for: cli)), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func cache(_ path: String, for cli: AgentCLI) {
        defaults?.set(path, forKey: cachedPathKey(for: cli))
    }

    // MARK: - 候选路径

    private static func candidateDirectories(for cli: AgentCLI) -> [String] {
        var directories = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        // `~/.claude/local/` 是 Claude Code 一种常见的自安装位置。
        if cli == .claude {
            directories.append("\(NSHomeDirectory())/.claude/local")
        }
        return directories
    }

    private static func candidatePaths(for cli: AgentCLI) -> [String] {
        candidateDirectories(for: cli).map { "\($0)/\(cli.rawValue)" }
    }

    // MARK: - 登录 shell 探测

    private static func whichPath(for cli: AgentCLI) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(cli.rawValue)"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) else {
            return nil
        }
        return output
    }
}
