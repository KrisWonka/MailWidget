// AgentRuntimePath.swift
// 「在 launchd job 和 LSUIElement 宿主 app 里跑外部 CLI 时，PATH 该是什么」的唯一权威。
//
// 这两种环境拿到的 PATH 都极窄：launchd 不给 job 继承登录 shell 的环境（这台机器上
// `launchctl getenv PATH` 返回空字符串，即落到系统默认的 `/usr/bin:/bin:/usr/sbin:/sbin`），
// LSUIElement 宿主 app 由 launchd 拉起同理。凡是要在这里面 spawn 外部 CLI 的代码都必须
// 自己把安装目录补回去——`DailyRegenerator`（app 内点「立即刷新」）和
// `DailySourceInstaller`（生成 launchd runner 脚本）两条路径共用这一份定义，避免漂移。

import Foundation

enum AgentRuntimePath {
    /// 常见 CLI 安装目录，顺序即优先级。末四项是系统默认 PATH，显式列出是为了让生成的
    /// 脚本即使不追加 `$PATH` 也自成一套完整环境。
    static let searchDirectories: [String] = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// 要跑 `executablePath` 这个可执行文件，PATH 里额外还需要哪些目录。
    ///
    /// 2026-09-13 第二台机器真机实录：Codex 的 9:00 日报任务连续三次 `exit 127`，日志里
    /// 只有一行 `env: node: No such file or directory`，10:21 放弃，于是 widget 停在前一天。
    /// 排查发现脚本里 codex **已经是绝对路径**（`/opt/homebrew/bin/codex`）——但那个文件
    /// 本身是个 `#!/usr/bin/env node` 的 npm 壳，**解释器仍然要走 PATH 去找**，而 launchd
    /// 的 PATH 里没有 `/opt/homebrew/bin`。所以「把 CLI 写成绝对路径」并不足以让它跑起来，
    /// 必须连它的 shebang 解释器一起解决。
    ///
    /// 为什么不能只靠上面那张静态候选表：nvm / fnm / volta 会把 node 装进版本化目录
    /// （`~/.nvm/versions/node/v22.3.0/bin/node`），任何写死的清单都覆盖不到。这里改为在
    /// **安装时**用登录 shell 把解释器解析一次，把它实际所在的目录钉进生成的脚本——运行时
    /// 再猜已经太晚（launchd 那会儿没有登录 shell 可用）。
    static func directoriesNeeded(toRun executablePath: String) -> [String] {
        var directories: [String] = []
        func append(_ directory: String) {
            guard !directory.isEmpty, !directories.contains(directory) else { return }
            directories.append(directory)
        }

        append((executablePath as NSString).deletingLastPathComponent)

        guard let interpreter = shebangInterpreter(of: executablePath) else { return directories }
        switch interpreter {
        case .absolute(let path):
            // `#!/usr/local/bin/python3` 这种自带绝对路径的不依赖 PATH，补上它所在目录
            // 只是顺带——真正要救的是下面 `env` 那支。
            append((path as NSString).deletingLastPathComponent)
        case .viaEnv(let tool):
            if let resolved = resolveViaLoginShell(tool) {
                append((resolved as NSString).deletingLastPathComponent)
            }
        }
        return directories
    }

    /// 生成给 shell 脚本用的 `export PATH=...` 整行。`extraDirectories` 排在最前，其后是
    /// 静态候选表，最后仍然接上 `$PATH` 本身——多一层兜底，且不会覆盖调用者刻意设过的值。
    static func exportStatement(extraDirectories: [String] = []) -> String {
        var merged: [String] = []
        for directory in extraDirectories + searchDirectories where !merged.contains(directory) {
            merged.append(directory)
        }
        return "export PATH=\"\(merged.joined(separator: ":")):$PATH\""
    }

    /// `Process.environment` 用的版本，语义与 `exportStatement` 一致。
    static func expandedEnvironment(extraDirectories: [String] = []) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var merged: [String] = []
        for directory in extraDirectories + searchDirectories + existing where !merged.contains(directory) {
            merged.append(directory)
        }
        environment["PATH"] = merged.joined(separator: ":")
        return environment
    }

    // MARK: - shebang 解析

    enum Interpreter: Equatable {
        case absolute(String)
        case viaEnv(String)
    }

    /// 只读文件头 256 字节：shebang 必须在第一行，而这些文件里 codex 那个壳有近百 KB，
    /// 没必要整个读进来。二进制文件（Mach-O）读到的头两个字节不是 `#!`，直接返回 nil。
    static func shebangInterpreter(of executablePath: String) -> Interpreter? {
        guard let handle = FileHandle(forReadingAtPath: executablePath) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256), !head.isEmpty else { return nil }

        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("#!") else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let tokens = firstLine.dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let first = tokens.first else { return nil }

        guard (first as NSString).lastPathComponent == "env" else {
            return .absolute(first)
        }
        // `#!/usr/bin/env -S node --flag` / `#!/usr/bin/env -i node`：跳过 env 自己的
        // 选项，取第一个不以 `-` 开头的词才是解释器名。
        for token in tokens.dropFirst() where !token.hasPrefix("-") {
            // `env -S` 常把后续参数挤在同一个词里（`-S node --enable-source-maps`），
            // 上面的分词已经拆开，这里取到的就是解释器名本身。
            return .viaEnv(token)
        }
        return nil
    }

    /// 用登录 shell 解析一个命令名的绝对路径。与 `AgentCLILocator.whichPath` 同形，但那边
    /// 只认 `AgentCLI` 枚举里的两个 CLI，这里要解析的是任意解释器名（node/python3/ruby…）。
    static func resolveViaLoginShell(_ tool: String) -> String? {
        // 命令名会被拼进 shell 命令行，只放行安全字符，避免把奇怪的 shebang 变成注入点。
        guard !tool.isEmpty,
              tool.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0) })
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(tool)"]
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
        guard !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) else { return nil }
        return output
    }
}
