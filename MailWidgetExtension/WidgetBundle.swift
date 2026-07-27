import WidgetKit
import SwiftUI

/// 两个 widget 共用一个 extension，但在桌面上是**各自独立**的组件，可以同时摆放，
/// 互不影响：MailWidget 渲染实时收件箱快照，DailySummaryWidget 渲染外部 agent
/// 推送进来的 Gmail 日报。
@main
struct MailWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        MailWidget()
        DailySummaryWidget()
    }
}
