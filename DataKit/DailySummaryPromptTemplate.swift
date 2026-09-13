// DailySummaryPromptTemplate.swift
// DataKit — 日报生产者契约的可移植模板（设计文档 §8）。
//
// 四个调度出口（Codex / Claude / 任意 CLI / 复制导出）全都从这里渲染，所以无论走哪条路，
// agent 拿到的指令和路径完全一致 —— 不会出现"Codex 那边对、别的 agent 那边少一句"。
//
// 渲染 = 把三个占位符替换成真实绝对路径。agent 不需要理解 `--source`：它已经写死在
// 渲染好的命令里了。

import Foundation

enum DailySummaryPromptTemplate {

    enum Placeholder: String, CaseIterable {
        case dataDirectory = "<DATA_DIR>"
        case ingestCommand = "<INGEST_CMD>"
        case cursorFile = "<CURSOR_FILE>"
        /// 邮箱未配置时的哨兵。`DailySummaryConstants.configuredMailbox` 是 nil 时，
        /// 正文里凡是原本要插入邮箱地址的地方都改插这一串，而不是悄悄渲染出一个
        /// 空字符串——`unresolvedPlaceholders(in:)` 把它当成普通占位符一并检出，
        /// 调用方（`DailySourceInstaller.renderedPrompt`、`DailyRegenerator`）已经
        /// 在用这个检查兜底半成品模板，邮箱缺失因此复用同一条报错路径，不需要
        /// 再新增一种"渲染不完整"的判定方式。
        case mailboxNotConfigured = "<<MAILBOX_NOT_CONFIGURED>>"
    }

    /// 宿主 app 的可执行文件路径。渲染 `<INGEST_CMD>` 用。
    ///
    /// 取当前运行的 app bundle 而不是硬编码 `/Applications/...`：从别处运行的构建产物
    /// 渲染出来的模板会指向它自己，避免把用户引到一个并不存在的路径。
    /// 2026-08-25 教训：这个属性曾被一个临时 harness 进程调用，于是把 harness 自己的
    /// 路径渲染进了 prompt 与 launchd 脚本——agent 忠实执行了那条命令、拿到退出码 0，
    /// 却什么也没发布，日报连着两天停在旧内容。所以只认"确实是 MailWidget.app 里的
    /// 那个可执行文件"，其余一律回落到安装路径。
    static let installedHostPath = "/Applications/MailWidget.app/Contents/MacOS/MailWidget"

    static var hostExecutableURL: URL {
        guard let executable = Bundle.main.executableURL,
              executable.lastPathComponent == "MailWidget",
              executable.pathComponents.contains("MailWidget.app")
        else {
            return URL(fileURLWithPath: installedHostPath)
        }
        return executable
    }

    static func ingestCommand(for sourceID: String) -> String {
        let executable = hostExecutableURL.path
        let payload = DailySummaryConstants.dataDirectoryURL
            .appendingPathComponent(DailySummaryConstants.summaryFilename).path
        return "\"\(executable)\" --ingest \"\(payload)\" --source \(sourceID)"
    }

    /// Codex 沿用它自己的 `memory.md` —— 那个文件已经存着历史增量游标，换文件会丢失
    /// 增量位置，导致邮件重复或漏报。其余来源各自用独立游标文件。
    static func cursorPath(for sourceID: String) -> String {
        if sourceID == DailySource.codex {
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".codex/automations/daily-gmail-summary/memory.md").path
        }
        return DailySource.cursorFileURL(for: sourceID).path
    }

    /// 渲染出可直接投喂给任意 agent 的完整提示词。
    static func render(for sourceID: String) -> String {
        var text = body
        let replacements: [Placeholder: String] = [
            .dataDirectory: DailySummaryConstants.dataDirectoryURL.path,
            .ingestCommand: ingestCommand(for: sourceID),
            .cursorFile: cursorPath(for: sourceID),
        ]
        for (placeholder, value) in replacements {
            text = text.replacingOccurrences(of: placeholder.rawValue, with: value)
        }
        return text
    }

    /// 渲染结果里不应残留任何占位符。导出前自检用，避免把半成品模板交给用户。
    static func unresolvedPlaceholders(in rendered: String) -> [Placeholder] {
        Placeholder.allCases.filter { rendered.contains($0.rawValue) }
    }

    // MARK: - 邮箱插值辅助

    /// 正文里"直接写邮箱地址"的地方用这个：配置了就用配置值，没配置就插哨兵——
    /// 绝不悄悄渲染出空字符串。
    /// 2026-09-13 第二台机器实录：提示词里把时区写死成 `America/New_York`（原作者所在
    /// 时区），而那台机器在 `America/Los_Angeles`。日报于是一直按东部时间判断「今日必办」
    /// 和「24 小时内的硬截止」，比本地早 3 小时——临近午夜时会把明天的事说成今天、把今天
    /// 已过期的事仍当作待办。`generatedAt` 也带着 -04:00 的偏移写进载荷。
    ///
    /// 这是去个人化时漏掉的一处：仓库里其它写死的个人信息都已参数化，唯独提示词正文里
    /// 这两处时区是纯文本，grep 个人邮箱/Team ID 时扫不到。改为读运行机器自己的时区。
    static var localTimeZoneIdentifier: String {
        TimeZone.current.identifier
    }

    private static func mailboxOrSentinel() -> String {
        DailySummaryConstants.configuredMailbox ?? Placeholder.mailboxNotConfigured.rawValue
    }

    /// gmailURL 示例里的邮箱是 URL query value，需要百分号编码（`@` → `%40`）。
    /// 用 RFC 3986 unreserved 字符集当白名单，其余一律编码——这与原先硬编码的字面量
    /// `you%40example.com`（只有 `@` 被编码）编码结果一致。
    private static let urlValueAllowedCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "-._~")
        set.formUnion(.alphanumerics)
        return set
    }()

    private static func percentEncodedMailboxOrSentinel() -> String {
        guard let mailbox = DailySummaryConstants.configuredMailbox else {
            return Placeholder.mailboxNotConfigured.rawValue
        }
        return mailbox.addingPercentEncoding(withAllowedCharacters: urlValueAllowedCharacters) ?? mailbox
    }

    // MARK: - 模板正文

    /// 曾是 `static let`：Swift 的 `static let` 只在首次访问时求值一次，此后永久缓存。
    /// 邮箱现在是运行时可变的（`DailySummaryConstants.configuredMailbox` 可以在首次
    /// 投递自动认领时才第一次被写入），`static let` 会把"第一次访问这个属性那一刻"
    /// 的邮箱（很可能还是空/哨兵）冻结进正文，后续配置变化再也反映不出来。改成
    /// 计算属性，每次访问都用当前配置重新插值。
    static var body: String {
        """
    You produce a daily Gmail decision brief for \(mailboxOrSentinel()) and \
    publish it to a macOS desktop widget. Write all user-visible text in concise, natural Chinese.

    ## Retrieval

    1. Read <CURSOR_FILE>. If it contains a cursor from a previously verified successful or \
    verified zero-message run, that cursor is authoritative. Use the last 24 hours only when no \
    cursor exists.
    2. Identify the connected Gmail profile. If it is exactly \(mailboxOrSentinel()), \
    search normally. Otherwise treat the connected account as an aggregate inbox that receives \
    \(mailboxOrSentinel())'s mail by forwarding: continue, but add a \
    `to:\(mailboxOrSentinel())` filter to every search below so mail addressed \
    to other accounts never enters the brief. Only stop and report the problem in Chinese when \
    Gmail access itself is missing.
    3. Search the strict incremental window with `after:<unix> -in:spam -in:trash`, plus the \
    `to:` filter when step 2 requires it.
    4. Read enough message and thread body content to judge real urgency. Deduplicate by \
    underlying event, merging the same event across threads, forwards, and notifications.

    ## Classification

    Assign each item exactly one level:

    - `immediate` — blocking or safety issue, or a hard deadline within 24 hours
    - `today` — a real action due today
    - `week` — a later follow-up
    - `optional` — an event or opportunity with no consequence for skipping
    - `info` — information requiring no action

    A message with no direct ask is not a task. An optional event is not a deadline. Use \
    \(localTimeZoneIdentifier) local time with a 24-hour clock. An event that already ended must \
    not remain an action recommendation.

    ## Publishing (all three steps are required)

    ### 1. Write the payload

    Create <DATA_DIR> if needed. Write UTF-8 JSON to a temporary sibling file, close it \
    completely, then atomically rename it over <DATA_DIR>/\(DailySummaryConstants.summaryFilename). \
    Never append and never expose a partially written payload.

    The root object contains exactly `schemaVersion`, `mailbox`, `generatedAt`, `headline`, \
    `items`:

    - `schemaVersion` — the number `1`
    - `mailbox` — `\(mailboxOrSentinel())`
    - `generatedAt` — report time as RFC 3339 with its \(localTimeZoneIdentifier) UTC offset
    - `headline` — the concise Chinese lead sentence
    - `items` — at most \(DailySummaryConstants.maximumItemCount) objects, ranked \
    `immediate > today > week > optional > info`

    Each item contains `id`, `level`, `title`, `detail`, `gmailURL`, and — whenever the header can \
    be retrieved — `messageIdHeader`:

    - `id` — the Gmail thread ID, or the message ID when no thread ID exists
    - `level` — one of the five machine values above
    - `title` / `detail` — short, readable Chinese. No search queries, counts, or state paths.
    - `gmailURL` — `https://mail.google.com/mail/u/0/?authuser=\
    \(percentEncodedMailboxOrSentinel())#all/<id>`, using that same `id`. Never put an email address in a \
    `/u/.../` path segment.
    - `messageIdHeader` — the RFC 5322 `Message-ID` of the exact message you summarized, with \
    surrounding angle brackets removed and no leading or trailing whitespace, e.g. \
    `20260726160340.13cbcf6413d3d6b2@mail.joinhandshake.com`. For a thread, use the most recent \
    message in it. Omit the key entirely when it cannot be retrieved — never emit an empty \
    string, a null, or a value still containing `<` or `>`. Retrieving this header is a \
    required step, not an optional enrichment: for every selected item, fetch the underlying \
    message's metadata headers (Gmail message get with format=metadata including the \
    Message-ID header) and copy the value before writing the payload. Omission is acceptable \
    only when that metadata call itself fails for the specific message. The widget uses it to \
    open the message directly in Apple Mail; rows without it fall back to opening Gmail in a \
    browser.

    On a verified zero-message run, publish `items: []` with a short Chinese `headline` saying \
    there is no new mail requiring attention.

    ### 2. Hand the payload to the widget

    After the atomic rename succeeds, run exactly:

    <INGEST_CMD>

    Exit code 0 means published. Exit code 3 means this source is not the one currently selected \
    in MailWidget's settings — that is not an error, the run simply did not publish. Any other \
    non-zero code means the payload was rejected; report it briefly in Chinese.

    ### 3. Advance the cursor

    Write the next incremental cursor to <CURSOR_FILE>. Store only timestamps, the cursor, the \
    expected and verified mailbox, the query, the outcome, and counts — never a prose copy of the \
    brief.

    ## Failure rules

    On missing Gmail access, connector failure, or incomplete retrieval: do not overwrite the payload, \
    do not run the ingest command, and do not advance the cursor. Preserve the last verified \
    publication and report the failure in Chinese.

    A publishing failure must not roll back an otherwise verified Gmail run.
    """
    }
}
