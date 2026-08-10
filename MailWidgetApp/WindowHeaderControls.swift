// WindowHeaderControls.swift
// 日报详情窗口（DailyDetailView）和邮件总结窗口（MailSummaryView）header 右上角
// 图标按钮组共用的样式常量 + ⚙️ 设置按钮组件。
//
// 用户对比两个窗口的截图反馈：header 长得不一样——一个是"↻ 重新总结 | ⏰ 自动化"
// 文字按钮，一个是"⚙️ 日报源设置 | ↻ | 未读数"。统一成两个窗口都是"左 ⚙️（图标
// only，无文字）→ 右 ↻（图标 only）"，⚙️ 一律打开 MailWidget 的设置窗口。字号/
// 间距在这里定义一次、两处引用，不会再各自漂移出不同的观感。

import SwiftUI

enum WindowHeaderIconStyle {
    /// header 内 ⚙️/↻ 两个图标按钮之间的水平间距。
    static let spacing: CGFloat = 10
    /// ⚙️/↻ 图标按钮的字号——比 `.caption`（本项目里其它次要小控件常用的字号，
    /// 比如 widget header 的 markAllRead/mailSummary 按钮）大一档：去掉文字标签
    /// 之后，图标本身要扛起"看得清、点得中"的责任，不能太小。
    static let font: Font = .body
}

/// ⚙️ 图标按钮：两个 host 窗口 header 共用同一个组件，打开 MailWidget 的设置窗口
/// （SwiftUI 内建的 `Settings` scene，`SettingsView`）。纯图标、无文字；
/// `.help("设置")` 补文字版的无障碍语义——原来两个窗口分别是"日报源设置"（带
/// 具体功能说明的长 tooltip）和没有这个入口，统一后两边都用这一句通用的。
struct WindowSettingsButton: View {
    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(WindowHeaderIconStyle.font)
        .help("设置")
    }
}
