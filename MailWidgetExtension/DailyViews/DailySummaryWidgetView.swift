// DailySummaryWidgetView.swift
// Gmail 日报 widget 的渲染。从原 GmailDailyWidget/WidgetExtension/ 搬入，
// 本步骤（合并）中渲染逻辑逐行保持不变 —— 视觉统一是下一步单独做的事，
// 分开才能在出问题时立刻分清是管线问题还是样式问题。

import SwiftUI
import WidgetKit

struct DailySummaryWidgetView: View {
    @Environment(\.widgetFamily) private var family

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

    private var itemLimit: Int {
        family == .systemLarge ? 6 : 3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 5) {
            header

            if let summary = entry.summary {
                // Medium 不重复显示 headline：header 已经占掉一行，再放 headline
                // 会把本就紧张的 158pt 挤到只剩两条邮件。
                if family == .systemLarge, !summary.headline.isEmpty {
                    Text(summary.headline)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }

                if summary.items.isEmpty {
                    emptyState
                } else {
                    itemList(summary.items)
                }
            } else {
                unavailableState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(family == .systemLarge ? 16 : 12)
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Gmail 日报", systemImage: "envelope.fill")
                .font(.headline)
            Spacer(minLength: 8)
            if let date = entry.summary?.generatedDate {
                Text(Self.generatedAtFormatter.string(from: date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func itemList(_ items: [DailySummaryItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(itemLimit)).indices, id: \.self) { index in
                let item = items[index]
                Link(destination: item.gmailURL) {
                    WidgetItemRow(item: item, showTwoDetailLines: family == .systemLarge)
                }
                .buttonStyle(.plain)

                if index < min(items.count, itemLimit) - 1 {
                    Divider()
                }
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
            RoundedRectangle(cornerRadius: 2)
                .fill(item.level.tint)
                .frame(width: 4, height: 31)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(showTwoDetailLines ? 2 : 1)
                }
            }

            Spacer(minLength: 4)
            Image(systemName: "arrow.up.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, showTwoDetailLines ? 5 : 3)
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
