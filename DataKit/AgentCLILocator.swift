// AgentCLILocator.swift
// DataKit — 定位 claude / codex 命令行可执行文件的路径。
//
// 去个人化背景：`MailSummarizer` 和 `DailyRegenerator` 曾经把 claude/codex 的可执行
// 文件路径写死为原作者本机的具体位置（`~/.local/bin/claude`、
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

    /// 文件存在 ≠ 能用——真机部署实录：朋友的 codex 0.137 文件在、可执行位也在，
    /// 但一跑 `codex exec` 就崩（"The 'gpt-5.6-sol' model requires a newer version of
    /// Codex"），而 `isInstalled` 只看文件存不存在，于是设置页一直显示"引擎就绪"，
    /// 实际每次生成都失败。这里额外跑一次 `<cli> --version`（轻量、不花钱，不像
    /// `exec` 那样会真的调用模型）来确认它至少能正常启动并退出成功。
    ///
    /// 返回 nil = 可用；返回非 nil = 不可用，内容是给用户看的中文原因。
    ///
    /// 结果缓存进 App Group（带时间戳），`unusableReasonCacheTTL` 内不重复探测——
    /// 每次打开设置页都真的 fork 一次子进程会有明显的卡顿感。
    static func unusableReason(for cli: AgentCLI) -> String? {
        if case let .hit(cached) = cachedUnusableReason(for: cli) {
            return cached
        }
        let reason = probeUnusableReason(executablePath: path(for: cli), cliDisplayName: cli.rawValue)
        cacheUnusableReason(reason, for: cli)
        return reason
    }

    /// 探测逻辑本体，绕开 App Group 缓存——供 `unusableReason(for:)` 调用，也供单测
    /// 直接注入路径（不经过真实的候选路径扫描/App Group 读写）。
    ///
    /// `executablePath` 为 nil，或指向一个不存在/不可执行的文件时，直接返回"未找到"
    /// 文案，不会启动任何进程（既不需要，也避免在缺失文件上浪费一次 15 秒的等待）。
    static func probeUnusableReason(
        executablePath: String?,
        cliDisplayName: String,
        timeout: TimeInterval = versionProbeTimeout
    ) -> String? {
        guard let executablePath, FileManager.default.isExecutableFile(atPath: executablePath) else {
            return "未找到 \(cliDisplayName) 命令行，请在设置里指定路径"
        }
        return probeVersion(path: executablePath, cliDisplayName: cliDisplayName, timeout: timeout)
    }

    // MARK: - unusableReason 缓存

    /// 10 分钟内不重复探测。
    private static let unusableReasonCacheTTL: TimeInterval = 10 * 60

    private enum UnusableReasonCacheLookup {
        case hit(String?)
        case miss
    }

    private static func unusableReasonKey(for cli: AgentCLI) -> String {
        "cliUnusableReason.\(cli.rawValue)"
    }

    private static func unusableReasonCheckedAtKey(for cli: AgentCLI) -> String {
        "cliUnusableReasonCheckedAt.\(cli.rawValue)"
    }

    private static func cachedUnusableReason(for cli: AgentCLI, now: Date = Date()) -> UnusableReasonCacheLookup {
        guard let checkedAt = defaults?.object(forKey: unusableReasonCheckedAtKey(for: cli)) as? Date,
              now.timeIntervalSince(checkedAt) < unusableReasonCacheTTL else {
            return .miss
        }
        // 空字符串代表"上次探测结果是可用（nil）"，不能直接当"没有缓存"处理。
        let stored = defaults?.string(forKey: unusableReasonKey(for: cli)) ?? ""
        return .hit(stored.isEmpty ? nil : stored)
    }

    private static func cacheUnusableReason(_ reason: String?, for cli: AgentCLI, now: Date = Date()) {
        defaults?.set(reason ?? "", forKey: unusableReasonKey(for: cli))
        defaults?.set(now, forKey: unusableReasonCheckedAtKey(for: cli))
    }

    // MARK: - `--version` 探测

    private static let versionProbeTimeout: TimeInterval = 15

    /// 跑一次 `<path> --version`，超时或非零退出码都视为"不可用"。
    /// 用看门狗队列 + `terminate()` 兜底超时——不用 `waitUntilExit` 的阻塞版本一等到底，
    /// 否则一个卡死的 CLI 会把设置页/首次探测的调用方一起拖死 15 秒以上直到系统自己出手。
    private static func probeVersion(path: String, cliDisplayName: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return "\(cliDisplayName) 无法启动（\(path)）：\(error.localizedDescription)"
        }

        let stateLock = NSLock()
        var timedOut = false
        let watchdogQueue = DispatchQueue(label: "com.kris.mailwidget.agentCLILocator.versionProbe")
        watchdogQueue.asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                stateLock.lock()
                timedOut = true
                stateLock.unlock()
                process.terminate()
            }
        }

        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

        stateLock.lock()
        let didTimeOut = timedOut
        stateLock.unlock()

        if didTimeOut {
            return "\(cliDisplayName) --version 超时（超过 \(Int(timeout)) 秒），可能版本不兼容或已损坏"
        }
        guard process.terminationStatus == 0 else {
            let output = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = output.isEmpty ? "退出码 \(process.terminationStatus)" : output
            return "\(cliDisplayName) 不可用：\(detail)"
        }
        return nil
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
