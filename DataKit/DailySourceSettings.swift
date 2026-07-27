// DailySourceSettings.swift
// DataKit — 日报来源的选择与仲裁（设计文档 §7）。
//
// 这里只做"谁写进来的 payload 算数"的判定。App 不托管任何定时任务的启停：
// 两侧 automation 可以同时装着、同时跑，仲裁保证只有当前选中的来源能写入。

import Foundation

enum DailySource {
    static let codex = "codex"
    static let claude = "claude"
    static let builtIn = [codex, claude]

    /// `^[a-z0-9][a-z0-9-]{0,31}$`。用于 `--source` 参数与导出模板的文件名，
    /// 收紧字符集是为了让它能安全地拼进游标文件名和 launchd label。
    static func isValidID(_ value: String) -> Bool {
        guard (1...32).contains(value.count) else { return false }
        guard let first = value.first, first.isASCII,
              first.isLowercase || first.isNumber else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLowercase || character.isNumber || character == "-")
        }
    }

    /// 每个来源用独立游标文件，互不干扰。
    ///
    /// Codex 是刻意的例外：它继续用自己的
    /// `~/.codex/automations/daily-gmail-summary/memory.md`，因为那个文件已经存着
    /// 历史增量游标，换文件会丢失增量位置、造成邮件重复或漏报。
    static func cursorFileURL(for sourceID: String) -> URL {
        DailySummaryConstants.dataDirectoryURL
            .appendingPathComponent("cursor-\(sourceID).md", isDirectory: false)
    }
}

enum DailySourceSettings {
    static let sourceKey = "dailySummarySource"
    static let knownSourcesKey = "dailySummaryKnownSources"
    static let lastSourceKey = "dailySummaryLastSource"
    static let lastIngestAtKey = "dailySummaryLastIngestAt"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    /// 当前选中的日报来源。默认 codex —— 保持合并前的既有行为。
    static var selectedSource: String {
        get {
            guard let value = defaults?.string(forKey: sourceKey),
                  DailySource.isValidID(value) else {
                return DailySource.codex
            }
            return value
        }
        set {
            guard DailySource.isValidID(newValue) else { return }
            defaults?.set(newValue, forKey: sourceKey)
        }
    }

    /// Settings 里 Picker 的选项。内置两个，用户接入其它 agent 时追加。
    static var knownSources: [String] {
        get {
            let stored = defaults?.stringArray(forKey: knownSourcesKey) ?? []
            let merged = DailySource.builtIn + stored.filter { !DailySource.builtIn.contains($0) }
            return merged.filter(DailySource.isValidID)
        }
        set {
            let extras = newValue
                .filter { DailySource.isValidID($0) && !DailySource.builtIn.contains($0) }
            defaults?.set(Array(Set(extras)).sorted(), forKey: knownSourcesKey)
        }
    }

    static func registerSource(_ sourceID: String) {
        guard DailySource.isValidID(sourceID) else { return }
        knownSources = knownSources + [sourceID]
    }

    static var lastSource: String? {
        defaults?.string(forKey: lastSourceKey)
    }

    static var lastIngestAt: Date? {
        defaults?.object(forKey: lastIngestAtKey) as? Date
    }

    static func recordSuccessfulIngest(source: String?, at date: Date = Date()) {
        defaults?.set(source ?? "", forKey: lastSourceKey)
        defaults?.set(date, forKey: lastIngestAtKey)
    }

    // MARK: - 仲裁

    enum Decision: Equatable {
        case accept
        /// 传入来源与当前选中的来源不符；不写入，保留上一份有效日报。
        case reject(incoming: String, selected: String)
    }

    /// `--source` 未传时一律接受。这是刻意留的向后兼容保险丝：即便
    /// `automation.toml` 漏改、没带上 `--source`，既有的每日运行也不会因此失败。
    static func decide(incomingSource: String?, selected: String = selectedSource) -> Decision {
        guard let incomingSource else { return .accept }
        return incomingSource == selected
            ? .accept
            : .reject(incoming: incomingSource, selected: selected)
    }
}
