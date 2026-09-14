// DailySummaryWidgetView.swift
// Gmail 日报 widget 的渲染。
//
// 版式：level 色条 + AI 标题 + 摘要，不再单独显示原始邮件那一行。
//
//   ✉ Gmail 日报  7月27日 09:03      详情  ▲1/2▼   3
//   ────────────────────────────────────────────────
//   总体总结（headline）
//   ────────────────────────────────────────────────
//   ▍● 第 1 件的标题
//     几行话总结
//   ────────────────────────────────────────────────
//   ▍第 2 件…
//
// 原来这里还有一行复用 MailWidget MessageRow 的「发件人 / 原始主题 / 相对时间」，
// 已经删掉：这类邮件大量来自 Canvas/Instructure 之类通知网关，发件人显示名恒为
// 某个人名、主题恒为模板套话（"...just sent you a message in Canvas."），跟 AI
// 中文标题并排看着像挂错了邮件，纯属噪音。未读信号没有丢——挪到标题行行首的圆点，
// 点击落点也没变，整块仍然跳 Mail.app（见 destination）。

import SwiftUI
import WidgetKit

struct DailySummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    let entry: DailySummaryEntry

    /// 原本固定用 America/New_York 显示，理由是"日报本身按纽约时间切窗口，跟着机器跑会让
    /// 『今天』的含义漂移"。2026-09-13 起这个前提没有了：提示词里的时区已改成跟随运行机器
    /// （见 `DailySummaryPromptTemplate.localTimeZoneIdentifier`，第二台机器在太平洋时区，
    /// 按东部判断「今日必办」早了 3 小时）。生成端既然跟随本机，显示端也必须跟随，否则
    /// 太平洋用户会看到一个比自己钟表快 3 小时的生成时间。
    private static let generatedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "M月d日"
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

            // 生成中时让位给计时器：这个日期是**上一份**日报的生成时间，马上就会被替换，
            // 是这一排里最没用的元素。不让位的话 329pt 宽的 header 装不下——实测渲染
            // 「生成中 14:59」+ 日期会把标题截成「Gmail…」，「日报」两个字直接没了
            // （header 溢出在这个 widget 上已经返工过一次，不能再犯）。
            // 上界是 14:59：`awaitingBriefSince` 超过 staleAfter(15 分钟) 就返回 nil，
            // 而看门狗 14 分钟就把进程杀了，所以计时器不可能出现三位数分钟。
            if entry.regenerateStartedAt == nil, let date = entry.brief?.generatedDate {
                Text(Self.generatedAtFormatter.string(from: date))
                    .font(WidgetTheme.metaFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            regenerateControl

            Spacer(minLength: 4)

            detailButton

            // 与 MailWidget 的差别：这里只要有内容就显示翻页键，单页时读作 1/1。
            // MailWidget 是 totalPages > 1 才显示，但日报条目本来就少（≤6），
            // 藏起来会让人以为功能没做。到头时按钮是空操作，不会误跳。
            if let pageInfo = entry.brief?.pageInfo {
                pageControls(pageInfo)
            }

            Text("\(entry.brief?.unreadCount ?? 0)")
                .font(.title2.weight(.bold))
                .foregroundStyle((entry.brief?.unreadCount ?? 0) > 0 ? Color.accentColor : Color.secondary)
        }
    }

    /// 重新触发当前日报源。走 `mailwidget://regenerateDaily`，由 AppDelegate 转发给
    /// `DailyRegenerator.regenerate()`。
    ///
    /// 生成中时原地换成「生成中 M:SS」——**带一个会自己走的计时器**。原先是静态的
    /// 「生成中…」，注释里写着"widget 不支持动画，静态文案是唯一能表达进行中的办法"，
    /// 这个判断不对：`Text(_:style:.timer)` 是 WidgetKit 专门为此提供的 API，由系统
    /// 自己走字，不需要重建 timeline。
    ///
    /// 为什么非要走字：这条路径一次真实运行 4–5 分钟（本机 8/23、8/24、9/14 三次实测
    /// 分别是 4:00、4:49、4:46）。五分钟盯着一个纹丝不动的「生成中…」，唯一合理的
    /// 推断就是它死了——2026-09-14 用户报的正是这个（"一直显示生成中…是不是坏了"），
    /// 而当时后台其实在正常工作。让时间跳起来，"还活着"这件事就不用解释了。
    ///
    /// `monospacedDigit()` 是必须的：数字等宽，秒数跳动时这一格宽度才不会左右抖，
    /// 也不会把同排的标题挤到换行（header 溢出在这个 widget 上返工过一次）。
    @ViewBuilder
    private var regenerateControl: some View {
        if let startedAt = entry.regenerateStartedAt {
            HStack(spacing: 3) {
                Text("生成中")
                Text(startedAt, style: .timer)
                    .monospacedDigit()
            }
            .font(WidgetTheme.metaFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
        } else {
            Link(destination: URL(string: "mailwidget://regenerateDaily")!) {
                Image(systemName: "arrow.clockwise")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(WidgetTheme.metaFont)
            .foregroundStyle(.secondary)
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
                    detailLines: detailLines
                )
                if index < visible.count - 1 {
                    Divider()
                }
            }
        }
    }

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

/// 一「份」：level 色条 + 未读点 + 标题 + 几行话总结。整块可点，直接进 Mail
/// （有 Message-ID 且本地库确认存在就打开那封信，否则退化成 gmailURL）。
///
/// 原来这里还接一行复用 MailWidget `MessageRow` 的原始邮件行（发件人/主题/相对
/// 时间），已删除——这类通知网关邮件的发件人/主题跟 AI 标题并排纯属噪音，见文件
/// 头注释。未读信号没有丢，挪到了标题行行首的圆点上。
private struct DailyBriefCard: View {
    let brief: DailyBriefItem
    let detailLines: Int

    var body: some View {
        Link(destination: destination) {
            summaryBlock
        }
        .buttonStyle(.plain)
    }

    /// 有 Message-ID 且本地 Mail 库确认存在就打开那封信；否则落到 Gmail 网页版。
    /// 原来这里还有一档"打开该账户的邮箱"兜底——那只是把 Mail 激活到"不知道哪个
    /// 邮箱"，对日报场景没意义（用户已反馈"跳到 Mail 不知道哪个"），已去掉。
    private var destination: URL {
        brief.mailURL ?? brief.item.gmailURL
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    unreadDot
                    Text(brief.item.title)
                        .font(WidgetTheme.rowTitleFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if !brief.item.detail.isEmpty {
                    Text(brief.item.detail)
                        .font(WidgetTheme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLines)
                }
            }

            Spacer(minLength: 4)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
    }

    /// 未读时是 MailWidget 同款实心点；已读保留等宽透明占位，标题不会跟着左右跳。
    private var unreadDot: some View {
        Circle()
            .fill(brief.isUnread ? Color.accentColor : Color.clear)
            .frame(width: 7, height: 7)
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
