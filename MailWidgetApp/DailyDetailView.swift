// DailyDetailView.swift
// 日报详细页面：widget 版式的完整版。
//
// 与 widget 的关系是"同一套版式，去掉尺寸约束"：
// - 结构完全一致：header → 分割线 → 总体总结 → 分割线 → 一份一份、之间分割
// - 去掉翻页与 ViewThatFits 降级 —— 这里能滚动，所有条目一次全展示、摘要不截断
// - 邮件那一行同样显示未读圆点 / 发件人 / 主题 / 相对时间，点击进 Mail.app
//
// 由 widget header 上那个小按钮经 `mailwidget://dailyDetail` 唤起。

import AppKit
import SwiftUI

struct DailyDetailView: View {
    @State private var brief: DailyBrief?
    @State private var statusMessage = "正在读取日报…"

    private static let generatedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetTheme.sectionSpacingLarge) {
            header
            Divider()

            if let brief {
                if !brief.headline.isEmpty {
                    Text(brief.headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                }

                if brief.items.isEmpty {
                    emptyState
                } else {
                    itemList(brief.items)
                }
            } else {
                ContentUnavailableView(
                    "暂无 Gmail 日报",
                    systemImage: "envelope.badge",
                    description: Text(statusMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(WidgetTheme.paddingLarge + 8)
        .frame(minWidth: 520, minHeight: 460)
        .task { reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label("Gmail 日报", systemImage: "envelope.fill")
                .font(.title3.weight(.semibold))

            if let date = brief?.generatedDate {
                Text(Self.generatedAtFormatter.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text("\(brief?.unreadCount ?? 0)")
                .font(.title2.weight(.bold))
                .foregroundStyle((brief?.unreadCount ?? 0) > 0 ? Color.accentColor : Color.secondary)
        }
    }

    private func itemList(_ items: [DailyBriefItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: WidgetTheme.rowSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    DetailBriefCard(brief: item)
                    if index < items.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "没有需要你处理的邮件",
            systemImage: "checkmark.circle",
            description: Text("新的行动项会在下次日报后出现。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        do {
            let summary = try DailySummaryStore().load()
            brief = DailyBrief.resolve(summary: summary, snapshot: SnapshotStore.load())
            statusMessage = "日报已载入"
        } catch {
            brief = nil
            statusMessage = error.localizedDescription
        }
    }
}

/// 与 widget 的 DailyBriefCard 同构：level 色条 + 标题 + 完整摘要，下面接那封信。
/// 差别只是这里不截断摘要、也不降级行数。
private struct DetailBriefCard: View {
    let brief: DailyBriefItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(brief.item.level.detailTint)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 3) {
                    Text(brief.item.title)
                        .font(.headline)
                    Text(brief.item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Link(destination: brief.item.gmailURL) {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("在浏览器里打开 Gmail")
            }
            .fixedSize(horizontal: false, vertical: true)

            mailRow
        }
        .padding(.vertical, 6)
    }

    /// 点击进 Mail.app。三档与 widget 一致：关联到就显示真实发件人/主题；没关联到但有
    /// Message-ID 仍然能跳那封信；都没有才退到打开邮箱。任何一档都不去浏览器。
    @ViewBuilder
    private var mailRow: some View {
        if let message = brief.message {
            Button {
                openInMail(message)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(message.isRead ? Color.clear : Color.accentColor)
                        .frame(width: 7, height: 7)
                    Text(message.sender)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(message.subject)
                        .font(.subheadline)
                        .foregroundStyle(message.isRead ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(message.date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
        } else if let url = brief.mailURL {
            Button {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(url, configuration: configuration)
            } label: {
                Label("在「邮件」里打开这封信", systemImage: "envelope")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
        } else {
            Button {
                MailAppOpener.openMailbox(accountName: nil)
            } label: {
                Label("在「邮件」里查看", systemImage: "tray")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
        }
    }

    private func openInMail(_ message: MessageSummary) {
        if let header = message.messageIdHeader,
           let url = MailMessageLink.url(forMessageIdHeader: header) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration)
            // 乐观已读：用户正要去 Mail 读它，未读点立刻消失，不必等下一轮抓取。
            SnapshotStore.applyLocalReadMark(messageIdHeader: header)
        } else {
            MailAppOpener.openMailbox(accountName: nil)
        }
    }
}

private extension DailySummaryLevel {
    var detailTint: Color {
        switch self {
        case .immediate: return .red
        case .today: return .orange
        case .week: return .blue
        case .optional: return .purple
        case .info: return .secondary
        }
    }
}
