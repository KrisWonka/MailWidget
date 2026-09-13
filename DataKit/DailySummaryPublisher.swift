// DailySummaryPublisher.swift
// DataKit — 发布一份日报载荷进 App Group：解码校验 → 来源仲裁 → 落盘 → 记录来源 → 刷新
// 邮件本地可用性。
//
// 这是 `MailWidgetApp/IngestCommand.swift`（`--ingest` 命令行入口）已经在做的那件事，
// 抽到 DataKit 里让 `DailyRegenerator` 的兜底发布路径也能复用同一套步骤，而不是自己
// 重新拼一遍、悄悄漂移出第二种"发布"语义。IngestCommand.swift 本身不改动——它继续
// 内联调用这几步，边界要求它不属于本次改动范围；额外多出的
// `flushWidgetCenterRequests`（等 WidgetCenter 一次round trip）是 CLI 模式专属的收尾
// （进程跑完 --ingest 立刻退出，得靠它续命等 reload 真正发出去），DailyRegenerator 所在
// 的宿主进程本来就常驻，不需要这一步，调用方各自处理 WidgetCenter reload。
//
// `Data(contentsOf:)` 抛的都是 `NSError`，跟 `DailySummaryPublisherError` 一起变成
// `publish(payloadURL:source:)` 抛出的可能错误，供调用方在日志里报出具体原因。

import Foundation

enum DailySummaryPublisherError: LocalizedError {
    /// 传入来源与当前选中的来源不符；不写入，保留上一份有效日报——与
    /// `IngestCommand` 退出码 3 的语义一致。
    case sourceRejected(incoming: String, selected: String)

    var errorDescription: String? {
        switch self {
        case let .sourceRejected(incoming, selected):
            return "已忽略来自 \(incoming) 的日报：当前日报源设置为 \(selected)。"
        }
    }
}

enum DailySummaryPublisher {
    /// 发布 `payloadURL` 指向的日报 JSON。成功返回解码后的 `DailySummary`（调用方可能
    /// 想用它的 `items.count` 之类的信息打日志）；来源不符或解码/校验/落盘失败都会抛错，
    /// 不写入任何字节——上一份有效日报永远不会被一份坏数据或错来源的数据顶掉。
    @discardableResult
    static func publish(payloadURL: URL, source: String?) throws -> DailySummary {
        if case let .reject(incoming, selected) = DailySourceSettings.decide(incomingSource: source) {
            throw DailySummaryPublisherError.sourceRejected(incoming: incoming, selected: selected)
        }

        let summary = try DailySummaryCodec.decode(Data(contentsOf: payloadURL))
        let store = try DailySummaryStore()
        try store.save(summary)
        DailySourceSettings.recordSuccessfulIngest(source: source)
        DailyLinkAvailabilityStore.refresh(for: summary.items.compactMap(\.messageIdHeader))
        return summary
    }
}
