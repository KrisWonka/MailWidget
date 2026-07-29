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
    }

    /// 宿主 app 的可执行文件路径。渲染 `<INGEST_CMD>` 用。
    ///
    /// 取当前运行的 app bundle 而不是硬编码 `/Applications/...`：从别处运行的构建产物
    /// 渲染出来的模板会指向它自己，避免把用户引到一个并不存在的路径。
    static var hostExecutableURL: URL {
        Bundle.main.executableURL
            ?? URL(fileURLWithPath: "/Applications/MailWidget.app/Contents/MacOS/MailWidget")
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

    // MARK: - 模板正文

    static let body = """
    You produce a daily Gmail decision brief for \(DailySummaryConstants.expectedMailbox) and \
    publish it to a macOS desktop widget. Write all user-visible text in concise, natural Chinese.

    ## Retrieval

    1. Read <CURSOR_FILE>. If it contains a cursor from a previously verified successful or \
    verified zero-message run, that cursor is authoritative. Use the last 24 hours only when no \
    cursor exists.
    2. Verify the connected Gmail profile is exactly \(DailySummaryConstants.expectedMailbox) \
    before searching. On mismatch or missing access, stop and report the problem in Chinese \
    without guessing.
    3. Search the strict incremental window with `after:<unix> -in:spam -in:trash`.
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
    America/New_York local time with a 24-hour clock. An event that already ended must not remain \
    an action recommendation.

    ## Publishing (all three steps are required)

    ### 1. Write the payload

    Create <DATA_DIR> if needed. Write UTF-8 JSON to a temporary sibling file, close it \
    completely, then atomically rename it over <DATA_DIR>/\(DailySummaryConstants.summaryFilename). \
    Never append and never expose a partially written payload.

    The root object contains exactly `schemaVersion`, `mailbox`, `generatedAt`, `headline`, \
    `items`:

    - `schemaVersion` — the number `1`
    - `mailbox` — `\(DailySummaryConstants.expectedMailbox)`
    - `generatedAt` — report time as RFC 3339 with its America/New_York UTC offset
    - `headline` — the concise Chinese lead sentence
    - `items` — at most \(DailySummaryConstants.maximumItemCount) objects, ranked \
    `immediate > today > week > optional > info`

    Each item contains `id`, `level`, `title`, `detail`, `gmailURL`, and — whenever the header can \
    be retrieved — `messageIdHeader`:

    - `id` — the Gmail thread ID, or the message ID when no thread ID exists
    - `level` — one of the five machine values above
    - `title` / `detail` — short, readable Chinese. No search queries, counts, or state paths.
    - `gmailURL` — `https://mail.google.com/mail/u/0/?authuser=\
    krisxia%40umich.edu#all/<id>`, using that same `id`. Never put an email address in a \
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

    On account mismatch, connector failure, or incomplete retrieval: do not overwrite the payload, \
    do not run the ingest command, and do not advance the cursor. Preserve the last verified \
    publication and report the failure in Chinese.

    A publishing failure must not roll back an otherwise verified Gmail run.
    """
}
