// DailyDetailView.swift
// 日报详细页面：widget 版式的完整版。
//
// 与 widget 的关系是"同一套版式，去掉尺寸约束"：
// - 结构完全一致：header → 分割线 → 总体总结 → 分割线 → 一份一份、之间分割
// - 去掉翻页与 ViewThatFits 降级 —— 这里能滚动，所有条目一次全展示、摘要不截断
// - 未读圆点画在标题行行首，点击整块进 Mail.app（原来单独一行的发件人 / 原始
//   主题 / 相对时间已删除，见 DetailBriefCard 的注释）
//
// 由 widget header 上那个小按钮经 `mailwidget://dailyDetail` 唤起。

import AppKit
import SwiftUI

/// 详情窗口的可观察状态，由 `AppDelegate` 持有单例并注入。
///
/// 为什么不让 `DailyDetailView` 自己 `@State`/`@StateObject` 一份：宿主窗口是复用的
/// （`AppDelegate.dailyDetailWindow` 单例 + `isReleasedWhenClosed = false`），
/// `NSHostingView(rootView:)` 只在窗口第一次创建时实例化一次 —— 视图自身的
/// `.task`/`.onAppear` 只会在这个 rootView 第一次出现于视图树时跑一次，第二次
/// `makeKeyAndOrderFront` 并不会让它们重新触发，窗口会一直显示首次打开时读到的旧日报。
/// `AppDelegate.showDailyDetailWindow()` 才是"要把这个窗口给用户看"的唯一入口
/// （详情按钮 / Dock 图标 reopen / 冷启动首次），所以让它在每次调用时都主动
/// `reload()` 这个共享的 model，不依赖 AppKit key/active 通知的时序。
final class DailyDetailModel: ObservableObject {
    @Published private(set) var brief: DailyBrief?
    @Published private(set) var statusMessage = "正在读取日报…"

    func reload() {
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

struct DailyDetailView: View {
    @ObservedObject var model: DailyDetailModel

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

            if let brief = model.brief {
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
                    description: Text(model.statusMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(WidgetTheme.paddingLarge + 8)
        .frame(minWidth: 520, minHeight: 460)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label("Gmail 日报", systemImage: "envelope.fill")
                .font(.title3.weight(.semibold))

            if let date = model.brief?.generatedDate {
                Text(Self.generatedAtFormatter.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            // ⚙️/↻ 图标按钮组：与邮件总结窗口的 header 统一样式（`WindowHeaderControls
            // .swift`）。⚙️ 通往 MailWidget 的设置窗口——本 app 是 LSUIElement：没有
            // 应用菜单，⌘, 打不开设置，此前唯一入口是菜单栏图标里的 Settings… ——
            // 而用户点 app 图标弹出来的是这个窗口，会先在这里找。日报源（Codex/Claude
            // 切换、一键添加定时任务）与邮件总结引擎/自动化现在都在 SettingsView 里，
            // 不需要这里的 tooltip 再单独说明其中一项功能。
            HStack(spacing: WindowHeaderIconStyle.spacing) {
                WindowSettingsButton()

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(WindowHeaderIconStyle.font)
                .help("重新读取日报")
            }

            Text("\(model.brief?.unreadCount ?? 0)")
                .font(.title2.weight(.bold))
                .foregroundStyle((model.brief?.unreadCount ?? 0) > 0 ? Color.accentColor : Color.secondary)
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
}

/// 与 widget 的 DailyBriefCard 同构：level 色条 + 未读点 + 标题 + 完整摘要。
/// 差别只是这里不截断摘要、也不降级行数。
///
/// 原来下面还接一行发件人/原始主题/相对时间（同一封信的真实邮件信息），已删除——
/// 这类邮件大量来自 Canvas/Instructure 之类通知网关，发件人显示名恒为某个人名、
/// 主题恒为模板套话，跟 AI 中文标题并排看着像挂错了邮件，纯属噪音。未读信号没有
/// 丢，挪到了标题行行首的圆点；点击整块仍然进 Mail.app，逻辑见 `openInMail()`。
private struct DetailBriefCard: View {
    let brief: DailyBriefItem

    var body: some View {
        Button {
            openInMail()
        } label: {
            summaryBlock
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
    }

    private var summaryBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(brief.item.level.detailTint)
                .frame(width: 4)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    unreadDot
                    Text(brief.item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
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

    /// 未读时是 MailWidget 同款实心点；已读保留等宽透明占位，标题不会跟着左右跳。
    private var unreadDot: some View {
        Circle()
            .fill(brief.isUnread ? Color.accentColor : Color.clear)
            .frame(width: 7, height: 7)
    }

    /// 与 widget 侧 `DailyBriefCard.destination` 同一套兜底：mailURL → `gmailURL`
    /// 浏览器兜底。不再落到 `MailAppOpener.openMailbox(accountName:)`——那只是把 Mail
    /// 激活到"不知道哪个邮箱"，正是用户反馈的"跳到 Mail 里不知道哪个"；日报条目
    /// 要么落到那封信本身，要么落到它在 Gmail 网页版里的位置，没有中间态。
    private func openInMail() {
        let url = brief.mailURL ?? brief.item.gmailURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration)
        // 乐观已读：用户正要去读它，未读点立刻消失，不必等下一轮抓取。
        if let header = brief.item.messageIdHeader {
            SnapshotStore.applyLocalReadMark(messageIdHeader: header)
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
