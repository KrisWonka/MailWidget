// DailySummaryStore.swift
// DataKit — 日报在 App Group 容器里的读写。路径 = 容器下 latest.json，原子写入。
//
// 与原 GmailDailyWidget 版本的唯一区别：App Group ID 直接取自 `SharedConstants`，
// 不再从 Info.plist 的 `AppGroupIdentifier` 键读取。MailWidget 侧的 SnapshotStore
// 本来就是这么做的，两边统一后少了一个"构建变量没注入进 plist"的失败模式。
//
// `init(containerURL:)` 保留，单元测试靠它注入临时目录。

import Foundation

struct DailySummaryStore {
    private let containerURL: URL
    private let fileManager: FileManager

    init(appGroupIdentifier: String = SharedConstants.appGroupIdentifier,
         fileManager: FileManager = .default) throws {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw DailySummaryStoreError.appGroupUnavailable(appGroupIdentifier)
        }

        self.init(containerURL: containerURL, fileManager: fileManager)
    }

    init(containerURL: URL, fileManager: FileManager = .default) {
        self.containerURL = containerURL
        self.fileManager = fileManager
    }

    var summaryURL: URL {
        containerURL.appendingPathComponent(
            DailySummaryConstants.summaryFilename,
            isDirectory: false
        )
    }

    /// 先校验再落盘：校验不通过就抛错且一个字节都不写，所以上一份有效日报永远不会被
    /// 一份坏数据顶掉。
    func save(_ summary: DailySummary) throws {
        let data = try DailySummaryCodec.encode(summary)
        try fileManager.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: summaryURL, options: .atomic)
    }

    func load() throws -> DailySummary {
        guard fileManager.fileExists(atPath: summaryURL.path) else {
            throw DailySummaryStoreError.noSummary
        }

        return try DailySummaryCodec.decode(Data(contentsOf: summaryURL))
    }
}

enum DailySummaryStoreError: LocalizedError {
    case appGroupUnavailable(String)
    case noSummary

    var errorDescription: String? {
        switch self {
        case let .appGroupUnavailable(identifier):
            return "无法访问 App Group：\(identifier)"
        case .noSummary:
            return "还没有收到 Gmail 日报"
        }
    }
}
