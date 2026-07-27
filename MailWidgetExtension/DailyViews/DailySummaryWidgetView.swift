// DailySummaryWidgetView.swift
// Gmail 日报 widget 的渲染。骨架（背景、外边距、字号阶梯、行间距、header 下的分隔线）
// 全部走 WidgetTheme，与 MailWidget 保持一致；日报自己的要素——level 色条、生成时间、
// headline、五级语义、空态/未初始化态两种文案——一个不少。

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

            if let summary = entry.summary {
                // Medium 不重复显示 headline：header 已经占掉一行，再放 headline
                // 会把本就紧张的 158pt 挤到只剩一两条邮件。
                if isLarge, !summary.headline.isEmpty {
                    Text(summary.headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                Divider()

                if summary.items.isEmpty {
                    emptyState
                } else {
                    itemList(summary.items)
                }
            } else {
                Divider()
                unavailableState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(isLarge ? WidgetTheme.paddingLarge : WidgetTheme.paddingMedium)
        .containerBackground(for: .widget) {
            WidgetTheme.background(colorScheme)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Gmail 日报", systemImage: "envelope.fill")
                .font(WidgetTheme.headerFont)
            Spacer(minLength: 8)
            if let date = entry.summary?.generatedDate {
                Text(Self.generatedAtFormatter.string(from: date))
                    .font(WidgetTheme.metaFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 行数由 `ViewThatFits` 挑，不再写死 3 / 6。
    ///
    /// 这是必需的，不是锦上添花：行标题从 `caption` 提到 `subheadline` 之后每行都变高，
    /// 去掉行间 Divider 省下的高度补不回来。Medium 只有约 158pt 可用，写死 3 行会溢出。
    /// 候选按从高到矮排列，`ViewThatFits` 取第一个真正放得下的。
    @ViewBuilder
    private func itemList(_ items: [DailySummaryItem]) -> some View {
        if isLarge {
            ViewThatFits(in: .vertical) {
                rows(items, count: 6)
                rows(items, count: 5)
                rows(items, count: 4)
                rows(items, count: 3)
                rows(items, count: 2)
                rows(items, count: 1)
            }
        } else {
            ViewThatFits(in: .vertical) {
                rows(items, count: 3)
                rows(items, count: 2)
                rows(items, count: 1)
            }
        }
    }

    private func rows(_ items: [DailySummaryItem], count: Int) -> some View {
        VStack(alignment: .leading, spacing: WidgetTheme.rowSpacing) {
            ForEach(Array(items.prefix(count))) { item in
                Link(destination: item.gmailURL) {
                    WidgetItemRow(item: item, showTwoDetailLines: isLarge)
                }
                .buttonStyle(.plain)
            }
        }
    }

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

private struct WidgetItemRow: View {
    let item: DailySummaryItem
    let showTwoDetailLines: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // level 色条 —— 日报独有的分级标识，对应 [立即]/[今天]/[本周]/[可选]/[知悉]。
            RoundedRectangle(cornerRadius: 2)
                .fill(item.level.tint)
                .frame(width: 4, height: 31)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(WidgetTheme.rowTitleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(WidgetTheme.metaFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(showTwoDetailLines ? 2 : 1)
                }
            }

            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(WidgetTheme.metaFont)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
