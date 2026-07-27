// WidgetPaging.swift
// DataKit — widget 翻页的共享状态。
//
// 从 MailWidgetExtension 下沉到这里：宿主 app 的日报详细页面也要读同一份分页模型，
// 而 extension 的类型 app 编译不到。这两个类型都是纯数据/UserDefaults 访问，
// 没有任何视图依赖，放在 DataKit 是它们本来就该在的位置。

import Foundation

/// Contract 9 — pagination state for a scope, attached to a `ResolvedScope` once
/// it's been sliced to the current page. `currentPage`/`totalPages` are 0-based /
/// 1-based respectively for display; `scopeID` is threaded through so the header's
/// ▲/▼ buttons can construct a `MailPageIntent` without needing the configuration
/// intent in scope.
struct PageInfo {
    let scopeID: String
    let currentPage: Int
    let totalPages: Int
}

/// Shared page-state key/read helper so `MailPageIntent` (write) and
/// `MailTimelineProvider` (read) agree on the exact same UserDefaults key format.
/// Per-scope, not per-widget-instance: two widgets configured to the same scope
/// page together. That's an accepted simplification of the AppIntents state
/// model, not an oversight — there's no per-widget-instance identifier available
/// to key on here.
enum PageState {
    static func key(forScopeID scopeID: String) -> String {
        "widgetPage.\(scopeID)"
    }

    static func currentPage(forScopeID scopeID: String) -> Int {
        let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
        return defaults?.integer(forKey: key(forScopeID: scopeID)) ?? 0
    }
}
