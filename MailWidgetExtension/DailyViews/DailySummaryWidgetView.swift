// DailySummaryWidgetView.swift
// Gmail 日报 widget 的渲染。
//
// 版式：总结与邮件交叉。
//
//   ✉ Gmail 日报  7月27日 09:03      详情  ▲1/2▼   3
//   ────────────────────────────────────────────────
//   总体总结（headline）
//   ────────────────────────────────────────────────
//   ▍第 1 件的标题
//     几行话总结
//     ● 发件人                              2天前     ← 真实邮件行
//       主题…
//   ────────────────────────────────────────────────
//   ▍第 2 件…
//
// 邮件那一行直接复用 MailWidget 的 MessageRow，所以两个 widget 是同一套零件：
// 未读圆点、发件人加粗、主题、相对时间、以及"点进 Mail.app"的跳转逻辑全部一致。

import SwiftUI
import WidgetKit

struct DailySummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    let entry: DailySummaryEntry

    /// 固定用 America/New_York 显示报告时间，不跟随机器时区 —— 日报本身就是按
    /// 纽约时间切窗口的，跟着机器跑会让"今天"的含义漂移。
    private static let generatedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: isLarge ? WidgetTheme.sectionSpacingLarge : WidgetTheme.sectionSpacingMedium
        ) {
            header
            Divider()

            if let brief = entry.brief {
                if !brief.headline.isEmpty {
                    Text(brief.headline)
                        .font(WidgetTheme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(isLarge ? 3 : 2)
                    Divider()
                }

                if brief.items.isEmpty {
                    emptyState
                } else {
                    briefList(brief.items)
                }
            } else {
                unavailableState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(isLarge ? WidgetTheme.paddingLarge : WidgetTheme.paddingMedium)
        .containerBackground(for: .widget) {
            WidgetTheme.background(colorScheme)
        }
    }

    // MARK: - Header

    /// 结构与 MailWidget 的 MailboxHeaderRow 对齐：标题、Spacer、辅助按钮、翻页、计数。
    /// 差别只有两处：日期紧贴在标题右侧；没有"全部已读"按钮（日报不需要）。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label("Gmail 日报", systemImage: "envelope.fill")
                .font(WidgetTheme.headerFont)
                .lineLimit(1)

            if let date = entry.brief?.generatedDate {
                Text(Self.generatedAtFormatter.string(from: date))
                    .font(WidgetTheme.metaFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            detailButton

            if let pageInfo = entry.brief?.pageInfo, pageInfo.totalPages > 1 {
                pageControls(pageInfo)
            }

            Text("\(entry.brief?.unreadCount ?? 0)")
                .font(.title2.weight(.bold))
                .foregroundStyle((entry.brief?.unreadCount ?? 0) > 0 ? Color.accentColor : Color.secondary)
        }
    }

    /// 进入宿主 app 的日报详细页面。走 `mailwidget://` 自有 scheme，由 AppDelegate 接。
    private var detailButton: some View {
        Link(destination: URL(string: "mailwidget://dailyDetail")!) {
            Image(systemName: "list.bullet.rectangle")
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// ▲ 上一页、▼ 下一页。到头时 targetPage 被夹回当前页，同页点击是空操作，
    /// 所以不需要额外的禁用态 —— 与 MailWidget 的做法一致。
    private func pageControls(_ pageInfo: PageInfo) -> some View {
        HStack(spacing: 4) {
            Button(intent: DailyPageIntent(targetPage: max(pageInfo.currentPage - 1, 0))) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)

            Text("\(pageInfo.currentPage + 1)/\(pageInfo.totalPages)")
                .foregroundStyle(.secondary)

            Button(intent: DailyPageIntent(targetPage: min(pageInfo.currentPage + 1, pageInfo.totalPages - 1))) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }

    // MARK: - 一份一份

    /// 候选按从高到矮排列，`ViewThatFits` 取第一个真正放得下的。每一份约 80pt，
    /// 比合并前的单行高得多，所以摘要行数也要参与降级，否则会在"3 份"和"2 份"之间
    /// 留下一大块空白。
    @ViewBuilder
    private func briefList(_ items: [DailyBriefItem]) -> some View {
        if isLarge {
            ViewThatFits(in: .vertical) {
                stack(items, count: 3, detailLines: 2)
                stack(items, count: 3, detailLines: 1)
                stack(items, count: 2, detailLines: 2)
                stack(items, count: 2, detailLines: 1)
                stack(items, count: 1, detailLines: 2)
                stack(items, count: 1, detailLines: 1)
            }
        } else {
            ViewThatFits(in: .vertical) {
                stack(items, count: 1, detailLines: 2)
                stack(items, count: 1, detailLines: 1)
            }
        }
    }

    private func stack(_ items: [DailyBriefItem], count: Int, detailLines: Int) -> some View {
        let visible = Array(items.prefix(count))
        return VStack(alignment: .leading, spacing: WidgetTheme.rowSpacing) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                DailyBriefCard(
                    brief: entry,
                    detailLines: detailLines,
                    mailAccountID: mailAccountID
                )
                if index < visible.count - 1 {
                    Divider()
                }
            }
        }
    }

    private var mailAccountID: String? { entry.mailAccountID }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("没有需要你处理的邮件", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
            Text("新的行动项会在下次日报后出现。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("等待第一份日报", systemImage: "clock")
                .font(.subheadline.weight(.medium))
            Text("日报生成后会自动刷新。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// 一「份」：level 色条 + 标题 + 几行话总结，下面接那封信本身。
///
/// 邮件那一行直接用 MailWidget 的 `MessageRow`，包括它自己的跳转逻辑
/// （有 Message-ID 就 `message://` 打开那封信，否则打开该账户的邮箱）。
/// 关联不到邮件时退化成一个指向 Mail 邮箱的链接，仍然不会掉进浏览器。
private struct DailyBriefCard: View {
    let brief: DailyBriefItem
    let detailLines: Int
    let mailAccountID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            summaryBlock
            mailBlock
        }
    }

    private var summaryBlock: some View {
        HStack(alignment: .top, spacing: 9) {
            // level 色条 —— 日报独有的分级标识，
            // 对应 [立即]/[今天]/[本周]/[可选]/[知悉]。
            RoundedRectangle(cornerRadius: 2)
                .fill(brief.item.level.tint)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 2) {
                Text(brief.item.title)
                    .font(WidgetTheme.rowTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !brief.item.detail.isEmpty {
                    Text(brief.item.detail)
                        .font(WidgetTheme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLines)
                }
            }

            Spacer(minLength: 4)

            Link(destination: brief.item.gmailURL) {
                Image(systemName: "arrow.up.right")
                    .font(WidgetTheme.metaFont)
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 三档，都落在 Mail.app 里：
    /// 1. 快照关联到了 → 直接用 MailWidget 的 MessageRow，真实发件人/主题/未读点/时间
    /// 2. 没关联到但有 Message-ID → 仍然给 `message://`，只是显示不出发件人和主题
    /// 3. 连 Message-ID 都没有 → 打开该账户的邮箱
    @ViewBuilder
    private var mailBlock: some View {
        if let message = brief.message, let accountID = brief.accountID {
            MessageRow(message: message, accountID: accountID)
                .padding(.leading, 13)
        } else if let url = brief.mailURL {
            mailLink(url, title: "在「邮件」里打开这封信", icon: "envelope")
        } else if let url = MailDeepLink.mailbox(accountID: mailAccountID), mailAccountID != nil {
            mailLink(url, title: "在「邮件」里查看", icon: "tray")
        }
    }

    private func mailLink(_ url: URL, title: String, icon: String) -> some View {
        Link(destination: url) {
            Label(title, systemImage: icon)
                .font(WidgetTheme.metaFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 13)
    }
}

private extension DailySummaryLevel {
    var tint: Color {
        switch self {
        case .immediate:
            return .red
        case .today:
            return .orange
        case .week:
            return .blue
        case .optional:
            return .purple
        case .info:
            return .secondary
        }
    }
}
