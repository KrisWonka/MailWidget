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
}

struct DailySummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailySummaryEntry {
        DailySummaryEntry(date: .now, summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DailySummaryEntry) -> Void) {
        completion(DailySummaryEntry(date: .now, summary: loadSummary() ?? .placeholder))
    }

    /// 日报是推送式的：来源 agent 写完 latest.json 会主动调 `--ingest`，由它触发
    /// reloadTimelines。这里的 4 小时只是兜底，防止推送那一环整个失效时 widget
    /// 永远停在旧内容上。
    func getTimeline(in context: Context, completion: @escaping (Timeline<DailySummaryEntry>) -> Void) {
        let entry = DailySummaryEntry(date: .now, summary: loadSummary())
        let nextFallbackRefresh = Calendar.current.date(byAdding: .hour, value: 4, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextFallbackRefresh)))
    }

    private func loadSummary() -> DailySummary? {
        try? DailySummaryStore().load()
    }
}

struct DailySummaryWidget: Widget {
    let kind = DailySummaryConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DailySummaryProvider()) { entry in
            DailySummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Gmail 日报")
        .description("把真正需要注意的邮件放到桌面；点任意一条直接打开 Gmail。")
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
