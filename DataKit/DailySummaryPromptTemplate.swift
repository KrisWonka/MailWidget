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
        case publishedFile = "<PUBLISHED_FILE>"
        case backlogFile = "<BACKLOG_FILE>"
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

    /// 游标文件一律放在本 app 自己的数据目录（`cursor-<source>.md`）。
    ///
    /// 历史上 codex 这一支特意指向 `~/.codex/automations/daily-gmail-summary/memory.md`，
    /// 理由是"那个文件已经存着历史增量游标，换文件会丢失增量位置"——那只是**原作者本机**
    /// 的情况。2026-09-15 第二台机器实录证明这个选择在全新安装上是错的：**codex 的沙箱把
    /// 它自己的 `~/.codex` 目录设为只读**，agent 每一轮都在输出里写
    /// 「`.codex` 目录受环境只读限制，游标未能写入；下次运行可能重复检索最近 24 小时邮件」，
    /// 于是游标永远写不进去、每次都重扫最近 24 小时、每次产出几乎同一份简报——用户的体感
    /// 就是"刷新是能刷新，但内容没怎么变"。
    ///
    /// 数据目录在 `~/Library/Application Support/GmailDailyWidget/`，落在 codex 沙箱的
    /// workdir（home）可写范围内，实测能写。旧位置的内容由
    /// `migrateLegacyCodexCursorIfNeeded()` 迁移过来，不丢增量位置。
    static func cursorPath(for sourceID: String) -> String {
        DailySource.cursorFileURL(for: sourceID).path
    }

    /// 旧的 codex 游标位置。保留常量是为了迁移，不再作为写入目标。
    static var legacyCodexCursorURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/automations/daily-gmail-summary/memory.md")
    }

    /// 把旧位置的 codex 游标搬到新位置。只在新位置还不存在、旧位置存在时搬一次——
    /// 新位置一旦有内容就以它为准，绝不覆盖。读旧位置只需要读权限（沙箱只挡写不挡读）。
    static func migrateLegacyCodexCursorIfNeeded(for sourceID: String) {
        guard sourceID == DailySource.codex else { return }
        let destination = DailySource.cursorFileURL(for: sourceID)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { return }
        let legacy = legacyCodexCursorURL
        guard manager.fileExists(atPath: legacy.path) else { return }
        try? manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? manager.copyItem(at: legacy, to: destination)
    }

    /// 渲染出可直接投喂给任意 agent 的完整提示词。
    static func render(for sourceID: String) -> String {
        migrateLegacyCodexCursorIfNeeded(for: sourceID)
        var text = body
        let replacements: [Placeholder: String] = [
            .dataDirectory: DailySummaryConstants.dataDirectoryURL.path,
            .ingestCommand: ingestCommand(for: sourceID),
            .cursorFile: cursorPath(for: sourceID),
            .publishedFile: DailySummaryPublisher.publishedMirrorURL.path,
            .backlogFile: DailySummaryPublisher.backlogURL.path,
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
    5. Read <PUBLISHED_FILE> and <BACKLOG_FILE> if they exist. The first is the brief currently \
    on the widget; the second holds items an earlier run judged worth showing but had to cut to \
    stay within the item limit — treat both exactly the same way below. The search \
    above only sees mail since the cursor, so without this step every run would throw away \
    items that are still open just because no new mail arrived about them. For each of its \
    items, decide whether it is still open. Keep it when its deadline or event time has not \
    passed yet and, for items that ask the user to reply or act, you find no evidence it was \
    already done — for a reply, check that thread for a message the user sent after the \
    item's date. Drop items that are done, expired, or superseded by newer mail about the \
    same event. A carried item keeps its original `id`, `gmailURL` and `messageIdHeader`; \
    refresh its `detail` and `level` when time has moved on (a `week` item due tomorrow is \
    now `immediate`). Before carrying an item, re-read its source message and rebuild the \
    `detail` from it: keep only what that message (or a reply in its thread) still supports. \
    Never copy a carried `detail` forward unchecked — an earlier run may have been wrong, and \
    carrying it would repeat the mistake every run from then on.

    The brief you publish is the union of still-open carried items and the new items, \
    deduplicated by underlying event, ranked as below, and cut to the item limit — when more \
    qualify than fit, drop the lowest-ranked ones whether they are new or carried. The \
    `headline` describes this whole union, not just the new mail.

    Whatever you cut for space is not discarded: write those items to <BACKLOG_FILE> as a JSON \
    array of item objects in the same shape as `items`, replacing its previous contents (an \
    empty array when nothing was cut). An item that was merely crowded out is still open, and \
    without this file it could never come back — its mail is older than the cursor, so no \
    later search would see it again.

    ## Classification

    Assign each item exactly one level:

    - `immediate` — blocking or safety issue, or a hard deadline within 24 hours
    - `today` — a real action due today
    - `week` — an action due within the next 7 days. A deadline further out is `info` \
    until it gets within a week, so it does not take a slot from something due sooner.
    - `optional` — an event or opportunity with no consequence for skipping
    - `info` — information requiring no action

    Within the same level, the item with the nearest deadline or event time ranks first; an \
    item with a real deadline outranks one without. A message with no direct ask is not a \
    task. An optional event is not a deadline. Use \
    \(localTimeZoneIdentifier) local time with a 24-hour clock. An event that already ended must \
    not remain an action recommendation.

    ## Accuracy

    The user acts on this brief, sometimes on deadlines, visas, money or enrollment, so a \
    wrong sentence does real harm. Every fact in a `title` or `detail` — a rule, requirement, \
    number, amount, date, ID, or who said what — must be stated in a message you read in this \
    run, by someone in a position to know it. Do not fill anything in from your own knowledge \
    or inference, and do not round a plausible guess into a statement.

    The user's own sent messages show what the user did or asked, never what the answer is. \
    A question the user asked stays open until a reply actually answers it. If the reply \
    only points elsewhere (a link, another office) and gives no answer, the brief says the \
    question is still unanswered and where to ask — it does not supply the answer.

    Advice is allowed only when it is labelled as advice and rests on facts that meet the rule \
    above. When you cannot find support for a detail, leave it out.

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

    On a verified zero-message run, still publish the carried items from step 5 with a fresh \
    `generatedAt` and `headline`; publish `items: []` only when nothing new arrived and nothing \
    carries over either. Always publish whatever you found: deciding on \
    your own not to publish is never correct. Whether an empty payload is allowed to replace \
    the brief currently on the widget is decided by the ingest command, not by you — when it \
    declines it prints `保留今天已发布的日报` and exits 0, which is success, not a rejection; \
    report it in Chinese and do not retry.

    ### 2. Hand the payload to the widget

    After the atomic rename succeeds, run exactly:

    <INGEST_CMD>

    Exit code 0 means published. Exit code 3 means this source is not the one currently selected \
    in MailWidget's settings — that is not an error, the run simply did not publish.

    If it fails because the App Group container cannot be reached, the payload you already wrote \
    is still fine and MailWidget publishes it itself right after you exit — say so plainly in \
    Chinese and treat the run as successful. This is expected whenever your own sandbox blocks \
    access to the container rather than anything being wrong with the payload; do not retry it, \
    do not rewrite the payload, and above all still advance the cursor in step 3. Any other \
    non-zero code means the payload itself was rejected; report that one briefly in Chinese.

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
