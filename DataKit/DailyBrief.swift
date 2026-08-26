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

    /// 这封信是否已经同步进本地 Mail 库（整个 Envelope Index，不是快照那 50 封的
    /// 窗口）：`true`/`false` 是 `MailLocalIndex.existsLocally` 查出的确定结论；
    /// `nil` = 没有记录——查询失败、还没来得及查、或者 header 缺失，一律算"未知"。
    /// 见下面 `mailURL` 的三态注释。
    let isKnownLocallyAvailable: Bool?

    /// 显式 init（而非纯用编译器合成的 memberwise init）：`isKnownLocallyAvailable`
    /// 给了默认值 nil（未知），这样 widget 图库预览等既有的三参数调用点
    /// （`DailySummaryWidget.swift` 的 placeholder）不用跟着这次改动一起改——
    /// "未知"本来就是它们那种手写示例数据的正确语义。
    init(item: DailySummaryItem, message: MessageSummary?, accountID: String?, isKnownLocallyAvailable: Bool? = nil) {
        self.item = item
        self.message = message
        self.accountID = accountID
        self.isKnownLocallyAvailable = isKnownLocallyAvailable
    }

    var id: String { item.id }

    /// 只有真正关联到邮件、且那封信未读，才算「还需要关注」。关联不到的一律不计入——
    /// 宁可少数，也不要让右上角那个数字变成猜的。
    var isUnread: Bool { message?.isRead == false }

    /// 在 Mail.app 里打开这封信的深链；三态语义（2026-08-26 修复 `MCMailErrorDomain
    /// error 1030`）：
    /// - 载荷里没有 Message-ID → nil（同现状，回落 gmailURL）。
    /// - `isKnownLocallyAvailable == false`（`MailLocalIndex` 明确查过整个本地
    ///   Envelope Index，没找到这个 header）→ **nil**。这封信根本没同步进本地
    ///   Mail（典型场景：日报总结的是 Gmail 里刚收到的新信，账户 IMAP 同步还没
    ///   追上），给 `message://` 只会让 Mail 弹 1030 错误框，必须回落 gmailURL。
    /// - `true` 或**没有记录**（未知——比如库不可读、还没来得及查）→ 照旧给
    ///   `message://`。这是"宁可尝试也不误伤"的既有取向的延续：早先版本拿"快照
    ///   命中"当跳转前提，结果把本来能正确打开的邮件挡成了兜底（快照只索引
    ///   `role == "inbox"`、每个最多 50 封，没命中不代表 Mail 里没有它）——这次
    ///   新增的是"整库查过、确认没有"这一条**更强**的否定证据，而不是重新引入
    ///   "没证据就当没有"的旧毛病。
    var mailURL: URL? {
        guard let header = item.messageIdHeader else { return nil }
        guard isKnownLocallyAvailable != false else { return nil }
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

    /// `linkAvailability`：header → 本地是否存在（`MailLocalIndex.existsLocally` 的
    /// 结果，经 `DailyLinkAvailabilityStore` 落盘）。默认现读一次 store——widget
    /// timeline 每次解析都会调用这里，读的是小文件不是重新查库，成本可忽略；
    /// 单测/宿主详情页需要固定输入时可以直接传一份构造好的 map 进来。
    static func resolve(
        summary: DailySummary?,
        snapshot: MailSnapshot?,
        linkAvailability: [String: Bool] = DailyLinkAvailabilityStore().load()
    ) -> DailyBrief? {
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
            let availability = item.messageIdHeader.flatMap { linkAvailability[$0] }
            return DailyBriefItem(
                item: item,
                message: matched?.message,
                accountID: matched?.accountID,
                isKnownLocallyAvailable: availability
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
