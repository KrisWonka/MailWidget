// IngestCommand.swift
// 宿主 app 的命令行入口：外部 agent 生成日报 JSON 后调用它写入 App Group 并刷新 widget。
//
//   MailWidget --ingest <path> [--source <id>]
//
// 退出码：0 成功 / 1 读取或校验失败 / 2 参数用法错误 / 3 来源与当前设置不符（设计文档 §7.1）。
//
// 从原 GmailDailyWidget/App/IngestCommand.swift 搬入。新增的只有 `--source` 解析与仲裁；
// `flushWidgetCenterRequests` 的 run-loop 等待逻辑一字未动 —— 它是必需的，见其文档注释。

import Dispatch
import Foundation
import WidgetKit

enum IngestCommand {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let flagIndex = arguments.firstIndex(of: "--ingest") else {
            return nil
        }
        guard arguments.indices.contains(flagIndex + 1) else {
            writeError("用法：MailWidget --ingest <latest.json> [--source <id>]")
            return 2
        }

        let inputURL = URL(fileURLWithPath: arguments[flagIndex + 1]).standardizedFileURL

        var source: String?
        if let sourceIndex = arguments.firstIndex(of: "--source") {
            guard arguments.indices.contains(sourceIndex + 1) else {
                writeError("用法：MailWidget --ingest <latest.json> [--source <id>]")
                return 2
            }
            let value = arguments[sourceIndex + 1]
            guard DailySource.isValidID(value) else {
                writeError("--source 取值非法：\(value)（只接受小写字母、数字与连字符，1–32 位）")
                return 2
            }
            source = value
        }

        // 仲裁放在读文件与校验之前：来源不对时连读都不用读，也绝不碰已有的日报。
        if case let .reject(incoming, selected) = DailySourceSettings.decide(incomingSource: source) {
            writeError("已忽略来自 \(incoming) 的日报：当前日报源设置为 \(selected)。上一份日报保持不变。")
            return 3
        }

        do {
            let summary = try DailySummaryCodec.decode(Data(contentsOf: inputURL))
            let store = try DailySummaryStore()
            try store.save(summary)
            DailySourceSettings.recordSuccessfulIngest(source: source)
            // 载荷已经落盘、退出码已经确定为「已发布」之后才刷新可用性 —— 这一步只是给
            // 详情页/widget 补一份"这封信本地 Mail 里有没有"的旁路信息，查询本身失败
            // （store 内部已吞掉）也不该让 ingest 从 0 变成别的码。
            DailyLinkAvailabilityStore.refresh(for: summary.items.compactMap(\.messageIdHeader))
            WidgetCenter.shared.reloadTimelines(ofKind: DailySummaryConstants.kind)
            flushWidgetCenterRequests()
            print("已更新 Gmail 日报：\(summary.items.count) 条" + (source.map { "（来源 \($0)）" } ?? ""))
            return 0
        } catch {
            writeError("Gmail 日报写入失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// `reloadTimelines` is fire-and-forget. In command-line ingest mode the app
    /// exits immediately, so keep its run loop alive until WidgetCenter has
    /// completed a subsequent round trip (or the safety timeout expires).
    private static func flushWidgetCenterRequests(timeout: TimeInterval = 2) {
        let completed = DispatchSemaphore(value: 0)
        WidgetCenter.shared.getCurrentConfigurations { _ in
            completed.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if completed.wait(timeout: .now()) == .success {
                return
            }

            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.05))
            )
        }
    }

    private static func writeError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }
}
