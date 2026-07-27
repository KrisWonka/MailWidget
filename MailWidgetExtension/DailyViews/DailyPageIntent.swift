// DailyPageIntent.swift
// 日报 widget 的翻页。与 MailPageIntent 同构，只是 reload 的 kind 不同 ——
// 两者共用 PageState 的 key 格式，靠各自的 scopeID 区分，互不干扰。
//
// 与 MailPageIntent 一样是普通 AppIntent 而非 WidgetConfigurationIntent：
// 默认 openAppWhenRun = false，所以点 ▲/▼ 在 extension 进程内完成，不会拉起宿主 app。

import AppIntents
import WidgetKit

struct DailyPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Change Gmail Daily Widget Page"

    @Parameter(title: "Target Page")
    var targetPage: Int

    init() {
        self.targetPage = 0
    }

    init(targetPage: Int) {
        self.targetPage = targetPage
    }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
        defaults?.set(targetPage, forKey: PageState.key(forScopeID: DailyBrief.scopeID))
        WidgetCenter.shared.reloadTimelines(ofKind: DailySummaryConstants.kind)
        return .result()
    }
}
