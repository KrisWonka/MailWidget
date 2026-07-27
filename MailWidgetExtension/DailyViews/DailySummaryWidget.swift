// DailySummaryWidget.swift
// Gmail 日报 widget 的 timeline provider 与 WidgetConfiguration。
// 从原 GmailDailyWidget/WidgetExtension/GmailDailyWidget.swift 搬入。
//
// 与原版的唯一区别：去掉了 `@main`/`WidgetBundle`（现在由 MailWidgetExtension 的
// WidgetBundle.swift 统一注册两个 widget），常量改用 `DailySummaryConstants`。

import SwiftUI
import WidgetKit

struct DailySummaryEntry: TimelineEntry {
    let date: Date
    let summary: DailySummary?

    /// MailWidget 本地快照里出现过的 RFC Message-ID 集合。
    ///
    /// 用来决定一条日报能不能安全地用 `message://` 打开那封具体的信：不在快照里，说明
    /// Mail 本地没有这封信，点下去只会开出一个空窗口，此时退一步打开该邮箱（仍在 Mail 里）。
    /// 快照每个收件箱存最近 50 封，而日报只覆盖最近 24 小时，所以正常情况命中率很高。
    let localMessageIDs: Set<String>

    /// 日报邮箱在 Mail.app 里对应的账户 ID。行主体拿不到具体某封信时的兜底目标——
    /// 打开 Mail 里那个邮箱，而不是掉进浏览器。
    let mailAccountID: String?

    init(
        date: Date,
        summary: DailySummary?,
        localMessageIDs: Set<String> = [],
        mailAccountID: String? = nil
    ) {
        self.date = date
        self.summary = summary
        self.localMessageIDs = localMessageIDs
        self.mailAccountID = mailAccountID
    }
}

struct DailySummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailySummaryEntry {
        DailySummaryEntry(date: .now, summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DailySummaryEntry) -> Void) {
        completion(
            DailySummaryEntry(
                date: .now,
                summary: loadSummary() ?? .placeholder,
                localMessageIDs: loadLocalMessageIDs(),
                mailAccountID: loadMailAccountID()
            )
        )
    }

    /// 日报是推送式的：来源 agent 写完 latest.json 会主动调 `--ingest`，由它触发
    /// reloadTimelines。这里的 4 小时只是兜底，防止推送那一环整个失效时 widget
    /// 永远停在旧内容上。
    func getTimeline(in context: Context, completion: @escaping (Timeline<DailySummaryEntry>) -> Void) {
        let entry = DailySummaryEntry(
            date: .now,
            summary: loadSummary(),
            localMessageIDs: loadLocalMessageIDs(),
            mailAccountID: loadMailAccountID()
        )
        let nextFallbackRefresh = Calendar.current.date(byAdding: .hour, value: 4, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextFallbackRefresh)))
    }

    private func loadSummary() -> DailySummary? {
        try? DailySummaryStore().load()
    }

    /// 日报邮箱在 Mail.app 里的账户 ID，按邮箱地址精确匹配。
    private func loadMailAccountID() -> String? {
        SnapshotStore.load()?.accounts
            .first { $0.email == DailySummaryConstants.expectedMailbox }?
            .id
    }

    /// 复用 MailWidget 那份已经在跑的收件箱快照，不额外读 Mail 的数据。
    private func loadLocalMessageIDs() -> Set<String> {
        guard let snapshot = SnapshotStore.load() else { return [] }
        return Set(
            snapshot.accounts
                .flatMap(\.mailboxes)
                .flatMap(\.messages)
                .compactMap(\.messageIdHeader)
        )
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

extension DailySummary {
    static let placeholder = DailySummary(
        schemaVersion: 1,
        mailbox: DailySummaryConstants.expectedMailbox,
        generatedAt: "2026-07-19T14:00:00Z",
        headline: "今天有 2 件事值得看",
        items: [
            DailySummaryItem(
                id: "placeholder-1",
                level: .today,
                title: "项目更新需要今天确认",
                detail: "发件人等待你的决定",
                gmailURL: URL(
                    string: "https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/placeholder-1"
                )!
            ),
            DailySummaryItem(
                id: "placeholder-2",
                level: .info,
                title: "实验室本周通知",
                detail: "无需回复，了解即可",
                gmailURL: URL(
                    string: "https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/placeholder-2"
                )!
            )
        ]
    )
}
