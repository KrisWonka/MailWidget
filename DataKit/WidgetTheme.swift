// WidgetTheme.swift
// DataKit — 两个 widget 共享的样式 token（设计文档 §6.1）。
//
// 所有初值都逐个取自 MailWidget 原有的字面量，所以这次抽取对 MailWidget 是纯重构，
// 渲染结果逐像素不变。Gmail 日报侧引用同一批 token 后，两个组件摆在桌面上才会像
// 同一套东西。
//
// 两个 widget 各自的独有要素（未读圆点 / level 色条、未读数 / 生成时间、翻页 /
// headline）都不在这里，它们本来就该各管各的。

import SwiftUI

enum WidgetTheme {

    /// 暗色用 #0D0D0F 而不是更温和的近黑：macOS 26+ 会在 `.containerBackground`
    /// 之上叠一层无法关闭的镜面/玻璃高光，把填充色提亮。比"真实目标色"更暗，才能让
    /// **合成后**的观感落在近黑。这个值是实机调出来的，改动前先在深色桌面上比对。
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x0F / 255)
            : Color.white
    }

    // MARK: - 外边距（按尺寸档位）

    static let paddingSmall: CGFloat = 12
    static let paddingMedium: CGFloat = 14
    static let paddingLarge: CGFloat = 16

    // MARK: - 纵向间距

    /// 顶层 VStack 的段间距。Small 最紧，Large/XL 最松。
    static let sectionSpacingSmall: CGFloat = 4
    static let sectionSpacingMedium: CGFloat = 6
    static let sectionSpacingLarge: CGFloat = 8

    /// 相邻两条内容行之间的距离。所有尺寸统一 —— 行与行的呼吸感不该随卡片大小变。
    static let rowSpacing: CGFloat = 6

    /// XL 双列之间的水平间距。
    static let columnSpacing: CGFloat = 20

    // MARK: - 字体阶梯

    /// 行内主标题：MailWidget 的发件人、日报的邮件标题。
    static let rowTitleFont: Font = .subheadline.weight(.semibold)

    /// 行内正文：MailWidget 的主题行。
    static let rowBodyFont: Font = .subheadline

    /// 次要信息：相对时间、摘要、日报的 detail、生成时间。
    static let metaFont: Font = .caption2

    /// 卡片顶部标题。
    static let headerFont: Font = .headline
}
