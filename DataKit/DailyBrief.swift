// DailyBrief.swift
// 把日报载荷与 MailWidget 的本地收件箱快照**关联**成一份可渲染的简报。
//
// 关联键是 RFC Message-ID —— 日报载荷里的 `messageIdHeader`。关联成功后，每一份
// 既有 AI 写的中文总结，又有那封信的真实发件人/主题/未读态/时间，于是日报可以直接
// 复用 MailWidget 的 MessageRow，两个 widget 成为同一套零件。
//
// 关联不到（Mail 本地没同步到这封信）时 `message` 为 nil，视图退化成只显示日报标题。

import Foundation

/// 一「份」：几行话总结 + 它对应的那封邮件。
struct DailyBriefItem: Identifiable {
    let item: DailySummaryItem
    let message: MessageSummary?
    let accountID: String?

    var id: String { item.id }

    /// 只有真正关联到邮件、且那封信未读，才算「还需要关注」。关联不到的一律不计入——
    /// 宁可少数，也不要让右上角那个数字变成猜的。
    var isUnread: Bool { message?.isRead == false }

    /// 在 Mail.app 里打开这封信的深链。
    ///
    /// **只取决于载荷里有没有 Message-ID，与快照是否关联到无关。** 快照只索引
    /// `role == "inbox"` 的邮箱、每个最多 50 封；一封信不在这个窗口里（比如已归档到
    /// 「所有邮件」）不代表 Mail 里没有它。早先版本拿"快照命中"当作跳转的前提，
    /// 结果把本来能正确打开的邮件挡成了兜底——快照的作用只是锦上添花地显示真实
    /// 发件人/主题/未读态，不该决定能不能跳。
    var mailURL: URL? {
        guard let header = item.messageIdHeader else { return nil }
        return MailMessageLink.url(forMessageIdHeader: header)
    }
}

struct DailyBrief {
    let headline: String
    let generatedDate: Date?
    let items: [DailyBriefItem]

    /// 右上角显示的数字：仍未读的条目数。这是**整份日报**的总数，不随翻页变化——
    /// 跟 MailWidget 的 unreadCount 语义一致（翻页只切可见范围，不改角标）。
    let unreadCount: Int

    let pageInfo: PageInfo?

    /// 日报只有一个范围，不像 MailWidget 那样按账户/VIP 分。用一个固定 scope ID
    /// 就能复用 MailWidget 那套 PageState（同一个 App Group key 格式）。
    static let scopeID = "gmail-daily"

    static func resolve(summary: DailySummary?, snapshot: MailSnapshot?) -> DailyBrief? {
        guard let summary else { return nil }

        var messagesByID: [String: (message: MessageSummary, accountID: String)] = [:]
        for account in snapshot?.accounts ?? [] {
            for mailbox in account.mailboxes {
                for message in mailbox.messages {
                    guard let header = message.messageIdHeader else { continue }
                    // 同一封信可能同时出现在 inbox 和 flagged 等伪邮箱里，先到先得即可，
                    // 内容一致。
                    if messagesByID[header] == nil {
                        messagesByID[header] = (message, account.id)
                    }
                }
            }
        }

        let items = summary.items.map { item -> DailyBriefItem in
            let matched = item.messageIdHeader.flatMap { messagesByID[$0] }
            return DailyBriefItem(
                item: item,
                message: matched?.message,
                accountID: matched?.accountID
            )
        }

        return DailyBrief(
            headline: summary.headline,
            generatedDate: summary.generatedDate,
            items: items,
            unreadCount: items.filter(\.isUnread).count,
            pageInfo: nil
        )
    }

    /// 切到当前页。页内实际显示几份仍由视图自己的 ViewThatFits 决定。
    func paginated(pageSize: Int) -> DailyBrief {
        guard pageSize > 0, !items.isEmpty else { return self }

        let totalPages = max(1, (items.count + pageSize - 1) / pageSize)
        let requested = PageState.currentPage(forScopeID: Self.scopeID)
        let currentPage = min(max(requested, 0), totalPages - 1)

        let start = currentPage * pageSize
        let end = min(start + pageSize, items.count)

        return DailyBrief(
            headline: headline,
            generatedDate: generatedDate,
            items: start < end ? Array(items[start..<end]) : [],
            unreadCount: unreadCount,
            pageInfo: PageInfo(
                scopeID: Self.scopeID,
                currentPage: currentPage,
                totalPages: totalPages
            )
        )
    }
}
