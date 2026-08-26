// DailyLinkAvailabilityStore.swift
// DataKit — 把 `MailLocalIndex.existsLocally` 的查询结果落盘到 App Group，供
// DailyBrief.resolve 读取，决定日报每条 mailURL 是给 `message://` 还是回落 gmailURL。
//
// 为什么要落盘而不是每次现查：这份可用性是"查一次本地 Mail 库"的结果，跟
// IngestCommand 落 latest.json、RefreshScheduler 定时/WAL 触发刷新是两条不同节奏
// 的流水线；把结果存成文件后，DailyBrief.resolve 每次解析（可能被 widget timeline
// 频繁调用）只是读一个小 JSON，不用每次都开 SQLite 连接查库。RefreshScheduler 每次
// 成功刷新快照后顺带 `refresh(for:)` 一次，邮件晚些同步进 Mail 后，链接会在下一轮
// 自动恢复成直达 Mail（详见 DailyBrief.mailURL 的三态注释）。
//
// 路径与 SnapshotStore 同一套约定：容器不可用（无 App Group entitlement 的 CLI
// harness）时 `load()` 直接返回空字典（等价于"没有任何记录"，调用方按未知处理）、
// `save(_:)` 抛错，不悄悄写到某个隐藏的兜底路径——这份数据纯粹是缓存，写不进去
// 大不了下一轮刷新再试，没必要为它单独引入一条 Application Support 降级路径。

import Foundation

struct DailyLinkAvailabilityStore {
    private let containerURL: URL?
    private let fileManager: FileManager

    private static let fileName = "daily-link-availability.json"

    private static var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// 生产用：探测真实 App Group 容器；不可用时 `containerURL` 为 nil，`load()`
    /// 返回空字典、`save(_:)` 抛错，不崩溃。
    init(fileManager: FileManager = .default) {
        self.containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        )
        self.fileManager = fileManager
    }

    /// 可测性入口：`containerURL` 顶替 App Group 容器，指向任意临时目录，方便单测
    /// 不碰真实 App Group 就能验证 save/load 往返。
    init(containerURL: URL, fileManager: FileManager = .default) {
        self.containerURL = containerURL
        self.fileManager = fileManager
    }

    private var fileURL: URL? {
        containerURL?.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// 读取上一次落盘的可用性 map（header → 本地是否存在）。容器不可用、文件不
    /// 存在、或文件损坏，一律返回空字典——空字典本身就是"未知"的正确表达，
    /// DailyBrief 对查不到记录的 header 一律按"未知"处理，不会把这里的空字典
    /// 误判成"确认所有邮件都不存在"。
    func load() -> [String: Bool] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    /// 原子写入。整份覆盖式保存——调用方（`refresh(for:)`）已经把"新查到的" +
    /// 需要保留的旧记录合并好，这里不做合并，语义和 SnapshotStore.save 一致。
    func save(_ map: [String: Bool]) throws {
        guard let fileURL else {
            throw DailyLinkAvailabilityStoreError.appGroupUnavailable(SharedConstants.appGroupIdentifier)
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(map)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// 便捷入口：对给定 headers 查本地 Mail 库并落盘，返回落盘后的完整 map。
    ///
    /// **合并而非整体替换**：只更新这次查询覆盖到的 header，其余已落盘的记录原样
    /// 保留。日报最多 6 条（`DailySummaryConstants.maximumItemCount`），但历史上
    /// 落过盘的 header 不该因为这次日报换了一批条目就被清空——万一某条旧日报的
    /// 详情页仍在展示，它的可用性记录还应该继续有效。
    ///
    /// `MailLocalIndex.existsLocally` 只在字典里放"确实查到结果"的 header，查询
    /// 失败（库暂时不可读等）的 header 不出现在返回值里，合并时天然保留旧记录，
    /// 不会被一次失败的查询误判成"确认不存在"。落盘失败（App Group 不可用等）
    /// 静默丢弃，不抛出、不影响调用方（RefreshScheduler）的主刷新流程。
    @discardableResult
    static func refresh(for headers: [String]) -> [String: Bool] {
        let cleaned = headers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return [:] }

        let store = DailyLinkAvailabilityStore()
        var merged = store.load()
        let queried = MailLocalIndex.existsLocally(messageIdHeaders: cleaned)
        for (header, exists) in queried {
            merged[header] = exists
        }

        try? store.save(merged)
        return merged
    }
}

enum DailyLinkAvailabilityStoreError: LocalizedError {
    case appGroupUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .appGroupUnavailable(identifier):
            return "无法访问 App Group：\(identifier)"
        }
    }
}
