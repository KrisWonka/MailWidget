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
        formatter.dateFormat = "M月d日"
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

            // 通往「日报源」设置（Codex / Claude 切换、一键添加定时任务）。
            // 本 app 是 LSUIElement：没有应用菜单，⌘, 打不开设置，此前唯一入口是
            // 菜单栏图标里的 Settings… —— 而用户点 app 图标弹出来的是这个窗口，
            // 会先在这里找。
            SettingsLink {
                Label("日报源设置", systemImage: "gearshape")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("选择日报由 Codex 还是 Claude 生成，或一键添加定时任务")

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("重新读取日报")

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
            // 标题与摘要整块可点，直接进 Mail —— 不再单独放一行"在邮件里打开"。
            Button {
                openInMail()
            } label: {
                summaryBlock
            }
            .buttonStyle(.plain)

            // 关联到快照时才有：真实发件人/主题/未读点/时间，点它同样进 Mail。
            if let message = brief.message {
                mailRow(message)
            }
        }
        .padding(.vertical, 6)
    }

    private var summaryBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(brief.item.level.detailTint)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(brief.item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(brief.item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }

    private func mailRow(_ message: MessageSummary) -> some View {
        Button {
            openInMail()
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
    }

    /// 有 Message-ID 就打开那封信，否则打开邮箱。任何一档都不去浏览器。
    private func openInMail() {
        if let url = brief.mailURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(url, configuration: configuration)
            // 乐观已读：用户正要去 Mail 读它，未读点立刻消失，不必等下一轮抓取。
            if let header = brief.item.messageIdHeader {
                SnapshotStore.applyLocalReadMark(messageIdHeader: header)
            }
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
