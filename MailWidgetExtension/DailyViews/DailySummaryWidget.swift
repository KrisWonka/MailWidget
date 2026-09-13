// DailySummaryWidget.swift
// Gmail 日报 widget 的 timeline provider 与 WidgetConfiguration。

import SwiftUI
import WidgetKit

struct DailySummaryEntry: TimelineEntry {
    let date: Date

    /// 日报载荷与本地收件箱快照关联后的结果。nil = 还没收到过任何日报。
    let brief: DailyBrief?

    /// 日报邮箱在 Mail.app 里的账户 ID。某一份关联不到具体邮件时的兜底跳转目标 ——
    /// 打开 Mail 里那个邮箱，而不是掉进浏览器。
    let mailAccountID: String?

    /// `DailyRegenerator.isRegenerating()` 的结果（15 分钟自动过期）。header 的
    /// ↻ 按钮据此换成「生成中…」文案。
    let isRegenerating: Bool

    init(date: Date, brief: DailyBrief?, mailAccountID: String? = nil, isRegenerating: Bool = false) {
        self.date = date
        self.brief = brief
        self.mailAccountID = mailAccountID
        self.isRegenerating = isRegenerating
    }
}

struct DailySummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailySummaryEntry {
        DailySummaryEntry(date: .now, brief: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DailySummaryEntry) -> Void) {
        completion(
            makeEntry(family: context.family)
                ?? DailySummaryEntry(date: .now, brief: .placeholder, isRegenerating: DailyRegenerator.isRegenerating())
        )
    }

    /// 日报是推送式的：来源 agent 写完 latest.json 会主动调 `--ingest`，由它触发
    /// reloadTimelines。这里的 4 小时只是兜底，防止推送那一环整个失效时 widget
    /// 永远停在旧内容上。
    func getTimeline(in context: Context, completion: @escaping (Timeline<DailySummaryEntry>) -> Void) {
        let entry = makeEntry(family: context.family)
            ?? DailySummaryEntry(date: .now, brief: nil, isRegenerating: DailyRegenerator.isRegenerating())
        let nextFallbackRefresh = Calendar.current.date(byAdding: .hour, value: 4, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextFallbackRefresh)))
    }

    private func makeEntry(family: WidgetFamily) -> DailySummaryEntry? {
        let snapshot = SnapshotStore.load()
        guard var brief = DailyBrief.resolve(summary: try? DailySummaryStore().load(), snapshot: snapshot) else {
            return nil
        }
        brief = brief.paginated(pageSize: Self.pageSize(for: family))

        let accountID = snapshot?.accounts
            .first { $0.email == DailySummaryConstants.expectedMailbox }?
            .id

        return DailySummaryEntry(
            date: .now,
            brief: brief,
            mailAccountID: accountID,
            isRegenerating: DailyRegenerator.isRegenerating()
        )
    }

    /// 每一「份」= 标题 + 几行话总结 + 一整行真实邮件，约 80pt。
    /// Medium 可用高度约 130pt（158 减去 padding），装完 header 与总结后只剩一份的位置；
    /// Large 约 313pt，能放三份。页内实际显示几份仍由视图的 ViewThatFits 决定。
    private static func pageSize(for family: WidgetFamily) -> Int {
        family == .systemLarge ? 3 : 1
    }
}

struct DailySummaryWidget: Widget {
    let kind = DailySummaryConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailySummaryProvider()) { entry in
            DailySummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Gmail 日报")
        .description("把真正需要注意的邮件放到桌面；点任意一条直接在「邮件」里打开。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

private extension DailyBrief {
    /// 只用于 widget 图库预览，WidgetKit 会自动打码，所以用像真的一样的示例文本。
    static let placeholder = DailyBrief(
        headline: "今天有 2 件事值得看：一个需要今天确认，一个只需了解。",
        generatedDate: Date(),
        items: [
            DailyBriefItem(
                item: DailySummaryItem(
                    id: "placeholder-1",
                    level: .today,
                    title: "项目更新需要今天确认",
                    detail: "发件人等待你的决定，下班前回复即可。",
                    gmailURL: URL(string: "https://mail.google.com/mail/u/0/?authuser=you%40example.com#all/placeholder-1")!
                ),
                message: MessageSummary(
                    id: "placeholder-1", messageIdHeader: nil,
                    sender: "Sarah Chen", senderEmail: "sarah@example.com",
                    subject: "Q3 planning doc — needs your sign-off",
                    snippet: "", date: Date().addingTimeInterval(-7200),
                    isRead: false, isFlagged: false
                ),
                accountID: "placeholder-account"
            ),
            DailyBriefItem(
                item: DailySummaryItem(
                    id: "placeholder-2",
                    level: .info,
                    title: "实验室本周通知",
                    detail: "无需回复，了解即可。",
                    gmailURL: URL(string: "https://mail.google.com/mail/u/0/?authuser=you%40example.com#all/placeholder-2")!
                ),
                message: MessageSummary(
                    id: "placeholder-2", messageIdHeader: nil,
                    sender: "Lab Announcements", senderEmail: "lab@example.edu",
                    subject: "Weekly seminar schedule",
                    snippet: "", date: Date().addingTimeInterval(-28800),
                    isRead: true, isFlagged: false
                ),
                accountID: "placeholder-account"
            ),
        ],
        unreadCount: 1,
        pageInfo: nil
    )
}
