// MailSummarizer.swift
// DataKit — 契约 12：邮件总结的编排层。同步执行完整链路：
// MailContentFetcher.fetch → 组装 prompt → `/Users/kris/.local/bin/claude -p <prompt>`
// → 解析+校验 stdout → MailSummaryStore.save。
//
// Process 调用手法完全照抄 DailyRegenerator（stdin 置空、cwd=HOME、PATH 注入
// /opt/homebrew/bin、日志落 ~/Library/Logs/）——唯一的差别是 DailyRegenerator
// 异步启动、立即返回，不等待、不解析 stdout；这里是 CLI/后台线程语境，
// 需要同步跑完整条链、拿到 stdout 解析，所以用 `waitUntilExit()` 阻塞等待
// （调用方保证不在主线程跑），并且把 stdout 单独用一个 Pipe 收进内存（同时也
// tee 一份进日志），stderr 只进日志不参与解析。
//
// 防重入 flag 与 DailyRegenerator 同款：15 分钟过期兜底，开始写入、结束（无论
// 成功/失败/异常）清除。

import Foundation

enum MailSummarizer {

    enum SummarizeError: Error, CustomStringConvertible {
        case unsupportedScope(String)
        case unknownAccount(String)
        case noMailsAvailable
        case claudeNotFound(String)
        case claudeLaunchFailed(String)
        case claudeTimedOut
        case claudeExitedNonZero(Int32)
        case noJSONObjectFound
        case jsonDecodeFailed(String)
        case storeUnavailable(String)

        var description: String {
            switch self {
            case .unsupportedScope(let scopeID):
                return "Unsupported scope for mail summary: \(scopeID)"
            case .unknownAccount(let scopeID):
                return "Cannot resolve account for scope \(scopeID) from current snapshot"
            case .noMailsAvailable:
                return "No mails with a usable Message-ID header were fetched"
            case .claudeNotFound(let path):
                return "claude executable not found at \(path)"
            case .claudeLaunchFailed(let message):
                return "Failed to launch claude: \(message)"
            case .claudeTimedOut:
                return "claude did not exit within the timeout; process was terminated"
            case .claudeExitedNonZero(let code):
                return "claude exited with non-zero status \(code)"
            case .noJSONObjectFound:
                return "No JSON object found in claude stdout"
            case .jsonDecodeFailed(let message):
                return "Failed to decode claude JSON output: \(message)"
            case .storeUnavailable(let message):
                return "Failed to save mail summary: \(message)"
            }
        }
    }

    /// 入选上限：MailContentFetcher 每账户先取够 20 封候选，这里再按
    /// "unread 优先、按日期倒序" 综合全部账户排序、截到总数 ≤20。
    static let maximumSelectedMails = 20

    /// claude 子进程超时；到点 terminate 并记为失败，不无限期挂起调用线程。
    static let claudeTimeout: TimeInterval = 10 * 60

    /// App Group defaults 里"正在生成"标志的过期兜底，跟 DailyRegenerator 同款 15 分钟。
    static let staleAfter: TimeInterval = 15 * 60

    private static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/mailwidget-mail-summary.log", isDirectory: false)

    private static let logQueue = DispatchQueue(label: "com.kris.mailwidget.mailSummarizer.log")

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

    static func startedAtKey(forScopeID scopeID: String) -> String {
        "mailSummaryStartedAt.\(scopeID)"
    }

    static func lastErrorKey(forScopeID scopeID: String) -> String {
        "mailSummaryLastError.\(scopeID)"
    }

    /// widget/窗口查询用：flag 存在且未过期。
    static func isGenerating(scopeID: String, now: Date = Date()) -> Bool {
        guard let startedAt = defaults?.object(forKey: startedAtKey(forScopeID: scopeID)) as? Date else {
            return false
        }
        return now.timeIntervalSince(startedAt) < staleAfter
    }

    /// 同步执行完整链路：fetch → prompt → claude -p → 解析校验 → store.save。
    /// 调用方（CLI 命令 / 窗口按钮触发的后台线程）负责不在主线程调用这个方法——
    /// 内部 `Process.waitUntilExit()` 会阻塞到 claude 退出或超时终止为止。
    @discardableResult
    static func summarize(scopeID: String) -> Bool {
        defaults?.set(Date(), forKey: startedAtKey(forScopeID: scopeID))
        defer { defaults?.removeObject(forKey: startedAtKey(forScopeID: scopeID)) }

        do {
            let (accountNames, scopeName) = try resolveScope(scopeID: scopeID)
            let fetched = try MailContentFetcher.fetch(accountNames: accountNames)
            let selected = selectMails(fetched)

            let items: [MailSummaryItem]
            if selected.isEmpty {
                // 没有可总结的邮件（收件箱为空，或都没有可用的 Message-ID 头）：
                // 落一份 items 为空的总结，而不是保留上一份过期结果或报错——
                // 跟日报"零消息也发布"的约定一致，窗口据此渲染空态而不是错误态。
                items = []
                log("scope=\(scopeID) 没有可总结的邮件，发布空总结")
            } else {
                let prompt = buildPrompt(scopeName: scopeName, mails: selected)
                log("scope=\(scopeID) 已选 \(selected.count) 封，prompt 长度 \(prompt.count) 字符，开始调用 claude")
                let stdout = try runClaude(prompt: prompt)
                let payloadItems = try parseClaudeOutput(stdout)
                items = reconcile(payloadItems: payloadItems, inputMails: selected)
            }

            let summary = MailSummary(
                schemaVersion: 1,
                scopeID: scopeID,
                scopeName: scopeName,
                generatedAt: Date(),
                items: items
            )
            do {
                try MailSummaryStore().save(summary)
            } catch {
                throw SummarizeError.storeUnavailable(String(describing: error))
            }

            clearLastError(scopeID: scopeID)
            log("scope=\(scopeID) 完成，items=\(items.count)")
            return true
        } catch {
            let message = String(describing: error)
            log("scope=\(scopeID) 失败：\(message)")
            recordLastError(scopeID: scopeID, message: message)
            return false
        }
    }

    // MARK: - Scope 解析

    /// `MailScope.all` → 不过滤账户（nil），scopeName "All Inboxes"；
    /// `account:<id>` → 从 SnapshotStore.load() 里按 AccountSummary.id 找该账户的
    /// name（envelopeIndex 通道的 id 是账户 UUID，appleScript 通道是合成 slug——
    /// 两种通道都是拿 `account.id == id` 精确匹配，不关心具体格式）；找不到就失败。
    /// 其余 scope（vip/flagged/未知字符串）一律失败——frontend 只在 all/account
    /// scope 显示总结入口，走到这里的其它字符串本就不该出现，fail-closed。
    static func resolveScope(scopeID: String) throws -> (accountNames: [String]?, scopeName: String) {
        if scopeID == MailScope.all {
            return (nil, "All Inboxes")
        }
        if scopeID.hasPrefix(MailScope.accountPrefix) {
            let accountID = String(scopeID.dropFirst(MailScope.accountPrefix.count))
            guard let snapshot = SnapshotStore.load(),
                  let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
                throw SummarizeError.unknownAccount(scopeID)
            }
            return ([account.name], account.name)
        }
        throw SummarizeError.unsupportedScope(scopeID)
    }

    // MARK: - 入选

    /// unread 优先、再按日期倒序，总数 ≤ maximumSelectedMails。没有 messageIdHeader
    /// 的邮件直接排除——MailSummaryItem.messageIdHeader 是必填字段，没有它既没法
    /// 校验模型输出、也没法在窗口里生成 message:// 深链，纳入了也无意义。
    static func selectMails(_ mails: [FetchedMail]) -> [FetchedMail] {
        let withHeader = mails.filter { $0.messageIdHeader != nil }
        let ranked = withHeader.sorted { lhs, rhs in
            if lhs.isRead != rhs.isRead {
                return !lhs.isRead // unread（isRead == false）排在前面
            }
            return lhs.date > rhs.date
        }
        return Array(ranked.prefix(maximumSelectedMails))
    }

    // MARK: - Prompt 组装

    private static let promptDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func buildPrompt(scopeName: String, mails: [FetchedMail]) -> String {
        var lines: [String] = []
        lines.append("You write concise Chinese summaries of specific emails for a macOS desktop widget list.")
        lines.append("Scope: \(scopeName).")
        lines.append("")
        lines.append("Summarize ONLY the emails listed below, one item per email. Do not invent, merge, or add any email not listed here.")
        lines.append("Output MUST be exactly one JSON object and nothing else: no markdown code fences, no leading or trailing prose, no explanation.")
        lines.append(#"Schema: {"items":[{"messageIdHeader":"...","summaryTitle":"中文一句话标题","summaryDetail":"中文概要 2-3 句，突出需要行动的点"}]}"#)
        lines.append("Copy each email's messageIdHeader back EXACTLY as given below, character for character. summaryTitle and summaryDetail must be Chinese.")
        lines.append("")
        lines.append("Emails:")
        for (index, mail) in mails.enumerated() {
            lines.append("### Email \(index + 1)")
            lines.append("messageIdHeader: \(mail.messageIdHeader ?? "")")
            lines.append("From: \(mail.sender) <\(mail.senderEmail)>")
            lines.append("Subject: \(mail.subject)")
            lines.append("Date: \(promptDateFormatter.string(from: mail.date))")
            lines.append("Read: \(mail.isRead ? "yes" : "no")")
            lines.append("Body (truncated):")
            lines.append(mail.bodyPrefix)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - claude 子进程

    private static let claudeExecutableURL = URL(fileURLWithPath: "/Users/kris/.local/bin/claude")

    private static func runClaude(prompt: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: claudeExecutableURL.path) else {
            throw SummarizeError.claudeNotFound(claudeExecutableURL.path)
        }

        let process = Process()
        process.executableURL = claudeExecutableURL
        process.arguments = ["-p", prompt]
        process.environment = expandedEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice

        let stdoutBox = OutputBox()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // stdout 既要进日志（可诊断）也要收进内存供解析；stderr 只进日志。
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stdoutBox.append(data)
            appendToLog(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            appendToLog(data)
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw SummarizeError.claudeLaunchFailed(error.localizedDescription)
        }

        let timeoutFlag = TimeoutFlag()
        let timeoutQueue = DispatchQueue(label: "com.kris.mailwidget.mailSummarizer.timeout")
        let timeoutWorkItem = DispatchWorkItem {
            timeoutFlag.value = true
            process.terminate()
        }
        timeoutQueue.asyncAfter(deadline: .now() + claudeTimeout, execute: timeoutWorkItem)

        // 同步等待：这是 CLI/后台线程语境（调用方保证不在主线程跑），不用 async API。
        process.waitUntilExit()
        timeoutWorkItem.cancel()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        // readabilityHandler 是异步触发的，进程退出那一刻管道里可能还剩最后一段没读到；
        // 用 readDataToEndOfFile 兜底读完剩余部分，避免 stdout 尾部被截断。
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBox.append(remainingStdout)
            appendToLog(remainingStdout)
        }
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            appendToLog(remainingStderr)
        }

        if timeoutFlag.value {
            throw SummarizeError.claudeTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw SummarizeError.claudeExitedNonZero(process.terminationStatus)
        }
        return stdoutBox.string
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

    /// 线程安全的字节缓冲：readabilityHandler 在后台 I/O 队列上追加，
    /// `runClaude` 在 waitUntilExit() 之后的调用线程上读取最终字符串。
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// 线程安全的超时标志：写在 timeoutQueue 上的 DispatchWorkItem 里，
    /// 读在 waitUntilExit() 返回之后的调用线程上。
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        var value: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return flag
            }
            set {
                lock.lock()
                flag = newValue
                lock.unlock()
            }
        }
    }

    // MARK: - stdout 解析与校验

    struct ClaudeSummaryItemPayload: Decodable {
        let messageIdHeader: String
        let summaryTitle: String
        let summaryDetail: String
    }

    private struct ClaudeSummaryPayload: Decodable {
        let items: [ClaudeSummaryItemPayload]
    }

    /// 取 stdout 里第一个 `{` 到最后一个 `}` 之间的子串——防御模型偶尔加
    /// ```json 围栏或前后闲话文字（"这是总结结果：\n```json\n{...}\n```"这种）。
    static func extractJSONObject(from stdout: String) -> String? {
        guard let firstBrace = stdout.firstIndex(of: "{"),
              let lastBrace = stdout.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }
        return String(stdout[firstBrace...lastBrace])
    }

    static func parseClaudeOutput(_ stdout: String) throws -> [ClaudeSummaryItemPayload] {
        guard let jsonSubstring = extractJSONObject(from: stdout),
              let data = jsonSubstring.data(using: .utf8) else {
            throw SummarizeError.noJSONObjectFound
        }
        do {
            let payload = try JSONDecoder().decode(ClaudeSummaryPayload.self, from: data)
            return payload.items
        } catch {
            throw SummarizeError.jsonDecodeFailed(String(describing: error))
        }
    }

    /// 用输入邮件集合（按 messageIdHeader 索引）校验+组装最终 items：
    /// - sender/subject 由本地 FetchedMail 回填，不采信模型输出（减少错位风险）；
    /// - messageIdHeader 在输入集里找不到匹配、或者是输入集内的重复值，该条目丢弃
    ///   并记日志，不让单条脏数据拖垮整次总结。
    static func reconcile(payloadItems: [ClaudeSummaryItemPayload], inputMails: [FetchedMail]) -> [MailSummaryItem] {
        var byHeader: [String: FetchedMail] = [:]
        for mail in inputMails {
            guard let header = mail.messageIdHeader else { continue }
            byHeader[header] = mail
        }

        var seenHeaders = Set<String>()
        var items: [MailSummaryItem] = []
        for payloadItem in payloadItems {
            let header = payloadItem.messageIdHeader
            guard let mail = byHeader[header] else {
                log("丢弃：messageIdHeader 不在输入集内：\(header)")
                continue
            }
            guard seenHeaders.insert(header).inserted else {
                log("丢弃：重复 messageIdHeader：\(header)")
                continue
            }
            items.append(MailSummaryItem(
                messageIdHeader: header,
                sender: mail.sender,
                subject: mail.subject,
                summaryTitle: payloadItem.summaryTitle,
                summaryDetail: payloadItem.summaryDetail
            ))
        }
        return items
    }

    // MARK: - lastError

    private static func recordLastError(scopeID: String, message: String) {
        defaults?.set(message, forKey: lastErrorKey(forScopeID: scopeID))
    }

    private static func clearLastError(scopeID: String) {
        defaults?.removeObject(forKey: lastErrorKey(forScopeID: scopeID))
    }

    // MARK: - 日志（照抄 DailyRegenerator 的行首加时间戳 + 串行队列写法）

    private static func log(_ message: String) {
        appendToLog("\(message)\n")
    }

    private static func appendToLog(_ data: Data) {
        appendToLog(String(decoding: data, as: UTF8.self))
    }

    private static func appendToLog(_ text: String) {
        guard !text.isEmpty else { return }
        logQueue.async {
            let timestamp = logTimestampFormatter.string(from: Date())
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var stamped = ""
            for (index, line) in lines.enumerated() {
                if index == lines.count - 1 && line.isEmpty { continue }
                stamped += "[\(timestamp)] \(line)\n"
            }
            guard let data = stamped.data(using: .utf8), !data.isEmpty else { return }
            appendData(data, to: logURL)
        }
    }

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
            // 日志本身写失败没有更好的兜底位置；静默丢弃，不影响总结主流程。
        }
    }
}
