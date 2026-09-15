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

    /// 一份**合法但零条目**的载荷会把今天已经发布过、还有内容的日报整个抹掉。
    /// 不是错误，是"这次没什么可更新的，保留上一份"。
    case emptyPayloadWouldEraseCurrentBrief(existingItemCount: Int)

    /// 载荷不是本次运行写出来的（或者已经有人发过更新的了）。同样不是错误。
    case staleForThisRun(reason: String)

    var errorDescription: String? {
        switch self {
        case let .sourceRejected(incoming, selected):
            return "已忽略来自 \(incoming) 的日报：当前日报源设置为 \(selected)。"
        case let .emptyPayloadWouldEraseCurrentBrief(existingItemCount):
            return "本次没有新邮件，保留今天已发布的日报（\(existingItemCount) 条）。"
        case let .staleForThisRun(reason):
            return "跳过发布：\(reason)"
        }
    }
}

/// 零条目载荷该不该覆盖已有日报——纯判定，方便单测直接喂值。
enum EmptyPayloadDecision: Equatable {
    case publish
    case keepExisting(existingItemCount: Int)
}

enum DailySummaryPublisher {
    /// 发布 `payloadURL` 指向的日报 JSON。成功返回解码后的 `DailySummary`（调用方可能
    /// 想用它的 `items.count` 之类的信息打日志）；来源不符或解码/校验/落盘失败都会抛错，
    /// 不写入任何字节——上一份有效日报永远不会被一份坏数据或错来源的数据顶掉。
    @discardableResult
    /// `notBefore` 非 nil 时额外做一层「这份载荷是不是本次运行写的」判定——**兜底发布**
    /// 专用。原先这条规则有两份实现：`DailyRegenerator` 里一份 Swift 判定（还会比
    /// `generatedAt`），launchd 脚本里一份 shell 判定（只比 mtime），严格程度不同。
    /// 现在统一收在这里，shell 那边只负责把本次尝试的起始时刻传进来。
    static func publish(payloadURL: URL, source: String?, notBefore: Date? = nil) throws -> DailySummary {
        if case let .reject(incoming, selected) = DailySourceSettings.decide(incomingSource: source) {
            throw DailySummaryPublisherError.sourceRejected(incoming: incoming, selected: selected)
        }

        let summary = try DailySummaryCodec.decode(Data(contentsOf: payloadURL))
        let store = try DailySummaryStore()

        if let notBefore {
            let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: payloadURL.path)[.modificationDate]) as? Date
            if case let .skip(reason) = freshnessDecision(
                stagingModifiedAt: modifiedAt,
                runStartedAt: notBefore,
                stagingGeneratedAt: summary.generatedDate,
                publishedGeneratedAt: (try? store.load())?.generatedDate
            ) {
                throw DailySummaryPublisherError.staleForThisRun(reason: reason)
            }
        }

        // 零条目守门。2026-09-14 实录：09:29 发布了一份带 `immediate` 的日报（回复
        // 口语诊所改约），用户 3 分钟后点了一下「立即刷新」，这次增量查询自然是零封
        // 新邮件，agent 按提示词规则发布 `items: []`，**把那条还没办的事整个抹掉了**，
        // 用户看到的就是"widget 什么都不显示了"。
        //
        // 根子在于日报是**增量**的（按游标），而 widget 把它当"当前待办清单"展示：
        // 刚跑完没多久再点一次刷新，几乎必然零新邮件，于是那个 ↻ 按钮成了清空待办的
        // 地雷。agent 自己也知道不对——它在运行输出里专门写了一段警告说"小组件现在
        // 被刷成了空的，但这件事还没办"——但它受提示词规则约束只能照做。
        //
        // 所以闸门放在这里而不是提示词里：提示词同步改了（见
        // `DailySummaryPromptTemplate`），但**发布层才是真闸门，agent 说什么不算数**，
        // 这是本仓库反复确认过的原则。
        if case let .keepExisting(count) = emptyPayloadDecision(
            incomingItemCount: summary.items.count,
            existing: try? store.load()
        ) {
            throw DailySummaryPublisherError.emptyPayloadWouldEraseCurrentBrief(existingItemCount: count)
        }

        try store.save(summary)
        DailySourceSettings.recordSuccessfulIngest(source: source)
        DailyLinkAvailabilityStore.refresh(for: summary.items.compactMap(\.messageIdHeader))
        return summary
    }

    /// 兜底发布该不该真的执行——纯判定，不碰文件系统/App Group，方便单测直接喂值。
    enum FreshnessDecision: Equatable {
        case publish
        /// `reason` 是给日志看的中文说明，不是错误。
        case skip(reason: String)
    }

    /// - Parameters:
    ///   - stagingModifiedAt: 交接目录 `latest.json` 的文件修改时间；文件不存在传 nil。
    ///   - runStartedAt: 本次 `regenerate()` 调用开始的时间。
    ///   - stagingGeneratedAt: 交接目录载荷里 `generatedAt` 字段解析出的时间；解析不出
    ///     （字段缺失、格式不对）传 nil——这不该挡住发布，真正的格式校验交给
    ///     `DailySummaryPublisher.publish` 的 `DailySummaryCodec.decode`。
    ///   - publishedGeneratedAt: App Group 里已经发布的日报的 `generatedAt`；App Group
    ///     里还没有日报（或读取失败）传 nil。
    static func freshnessDecision(
        stagingModifiedAt: Date?,
        runStartedAt: Date,
        stagingGeneratedAt: Date?,
        publishedGeneratedAt: Date?
    ) -> FreshnessDecision {
        guard let stagingModifiedAt else {
            return .skip(reason: "交接目录里没有 latest.json，agent 大概率没走到写文件那一步")
        }
        guard stagingModifiedAt >= runStartedAt else {
            return .skip(reason: "latest.json 是本次运行开始之前留下的旧文件，跳过兜底发布")
        }
        guard let publishedGeneratedAt else {
            return .publish
        }
        guard let stagingGeneratedAt else {
            // 载荷确实是这次运行写的，只是 generatedAt 解析不出来——不能据此判断新旧，
            // 宁可放行让真正的发布步骤去做完整校验，也不要因为一个次要字段漏发。
            return .publish
        }
        guard stagingGeneratedAt > publishedGeneratedAt else {
            return .skip(reason: "App Group 里已经是不早于这份载荷的日报，agent 大概率已经自己发布过了")
        }
        return .publish
    }

    static func emptyPayloadDecision(incomingItemCount: Int, existing: DailySummary?) -> EmptyPayloadDecision {
        emptyPayloadDecision(
            incomingItemCount: incomingItemCount,
            existingItemCount: existing?.items.count ?? 0,
            existingGeneratedAt: existing?.generatedDate
        )
    }

    /// 边界取「同一个自然日」而不是某个拍脑袋的时长：日报本来就是按天的东西。
    ///
    /// - 今天已经发过有内容的日报 → 零条目载荷一律不覆盖（这就是本次的 bug）。
    /// - 已有的是**昨天**的 → 放行。新的一天该重新开始，定时任务发空日报是正常行为。
    /// - 已有的本来就是空的 → 放行（空盖空，无所谓）。
    ///
    /// ⚠️ 已知没解决的那一半：一条**昨天**发布、今天仍然要办的事（比如"明早 10:00
    /// 的约"），会在第二天早上的空日报里消失。真正的解法是让条目有生命周期、跨天
    /// 结转未完成项，那是另一个功能，不在这次修复范围里。
    static func emptyPayloadDecision(
        incomingItemCount: Int,
        existingItemCount: Int,
        existingGeneratedAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EmptyPayloadDecision {
        guard incomingItemCount == 0 else { return .publish }
        guard existingItemCount > 0, let existingGeneratedAt else { return .publish }
        guard calendar.isDate(existingGeneratedAt, inSameDayAs: now) else { return .publish }
        return .keepExisting(existingItemCount: existingItemCount)
    }
}
