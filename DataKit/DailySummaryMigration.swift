// DailySummaryMigration.swift
// DataKit — 把合并前 GmailDailyWidget 独立 App Group 里的日报搬到 MailWidget 的容器（设计文档 §11.1）。
//
// 只在宿主 app 启动时跑一次。旧容器的文件**保留不删**：万一新链路有问题，
// 旧 app 还能读到它自己的数据。

import Foundation

enum DailySummaryMigration {
    static let flagKey = "didMigrateGmailDailyData"

    /// 合并前的 App Group。Team 前缀从当前 App Group ID 推导，不再硬编码一遍，
    /// 避免换团队时两处不同步。
    static var legacyAppGroupIdentifier: String? {
        let current = SharedConstants.appGroupIdentifier
        guard let dotIndex = current.firstIndex(of: ".") else { return nil }
        let teamPrefix = current[current.startIndex..<dotIndex]
        return "\(teamPrefix).com.kris.GmailDailyWidget"
    }

    @discardableResult
    static func runIfNeeded(fileManager: FileManager = .default) -> Bool {
        let defaults = UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
        guard defaults?.bool(forKey: flagKey) != true else { return false }

        defer { defaults?.set(true, forKey: flagKey) }

        guard let currentContainer = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: SharedConstants.appGroupIdentifier
        ) else {
            return false
        }

        let destination = currentContainer
            .appendingPathComponent(DailySummaryConstants.summaryFilename, isDirectory: false)

        // 新容器已经有日报了，说明已经有来源在正常写入，不要用旧数据盖掉它。
        guard !fileManager.fileExists(atPath: destination.path) else { return false }

        guard let legacyIdentifier = legacyAppGroupIdentifier,
              let legacyContainer = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: legacyIdentifier
              ) else {
            return false
        }

        let source = legacyContainer
            .appendingPathComponent(DailySummaryConstants.summaryFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: source.path) else { return false }

        do {
            try fileManager.createDirectory(
                at: currentContainer,
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
    }
}
