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

/// 让 launchd 脚本也能标记「日报正在生成」。
///
/// 为什么需要：`dailyRegenerateStartedAt` 原先只有 app 内那条路径会写，定时任务跑的时候
/// 这个标志是空的。后果有两个，第二个才是要害——
///   1. 定时任务跑着的时候 widget 上没有任何进行中提示；
///   2. **两条路径之间没有互斥**：早上 9 点任务正在跑，用户点一下 ↻，`regenerate()` 的
///      防重入判据（`guard !isRegenerating()`）看不到它，于是并发起第二个 agent，两个
///      一起往同一个 latest.json 写、各自推进游标。这正是 2026-09-14 修过的同一类问题，
///      只是当时只在 app 内那条路径上修了。
///
/// 标志本身仍然 15 分钟自动过期（`AgentRunPolicy.staleAfter`），所以脚本被强杀、机器断电
/// 之类的情况不会让 widget 永久卡住。
enum DailyRunMarkerCommand {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: "--daily-run") else { return nil }
        guard arguments.indices.contains(index + 1) else {
            writeError("用法：MailWidget --daily-run <start|end>")
            return 2
        }
        switch arguments[index + 1] {
        case "start":
            DailyRegenerator.markRunStarted()
            IngestCommand.flushWidgetCenterRequests()
            // 读回来确认真的写进去了。这条不是装饰：2026-09-15 实测发现写完立刻
            // `Darwin.exit` 时值可能落不了盘，而这个标志一旦丢了，两条路径之间就失去
            // 互斥、widget 也不显示进行中。宁可在脚本日志里留一行可见的凭据。
            guard DailyRegenerator.isRegenerating() else {
                writeError("已标记开始，但读回来是空的——标志没有生效")
                return 1
            }
            print("已标记日报生成中")
            return 0
        case "end":
            DailyRegenerator.markRunFinished()
            IngestCommand.flushWidgetCenterRequests()
            guard !DailyRegenerator.isRegenerating() else {
                writeError("已标记结束，但标志仍在——清除没有生效")
                return 1
            }
            print("已清除日报生成中标记")
            return 0
        default:
            writeError("--daily-run 只接受 start 或 end")
            return 2
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

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

        // `--not-before <unix>`：兜底发布专用，见 `DailySummaryPublisher.publish` 的说明。
        // launchd 脚本把本次尝试的起始时刻交给我们判断，它自己不再做这个判断——原先
        // shell 里那份判据比 Swift 那份宽松（只比 mtime、不比 generatedAt）。
        var notBefore: Date?
        if let index = arguments.firstIndex(of: "--not-before") {
            guard arguments.indices.contains(index + 1),
                  let seconds = TimeInterval(arguments[index + 1]) else {
                writeError("--not-before 需要一个 Unix 时间戳（秒）")
                return 2
            }
            notBefore = Date(timeIntervalSince1970: seconds)
        }

        // 发布链路走 `DailySummaryPublisher.publish` 这一条，不再在这里重写一遍。
        // 原先这里和 publisher 各有一份"解码 → save → recordSuccessfulIngest →
        // refresh 可用性"，两份会漂移——2026-09-14 加零条目守门时就发现只改 publisher
        // 根本拦不住真正的入口（agent 调的是 `--ingest`，走的是这里）。这个仓库已经
        // 因为"两条路径本该同构却各写一份"栽过四次，不再增加第五次。
        do {
            let summary = try DailySummaryPublisher.publish(
                payloadURL: inputURL,
                source: source,
                notBefore: notBefore
            )
            WidgetCenter.shared.reloadTimelines(ofKind: DailySummaryConstants.kind)
            flushWidgetCenterRequests()
            print("已更新 Gmail 日报：\(summary.items.count) 条" + (source.map { "（来源 \($0)）" } ?? ""))
            return 0
        } catch let error as DailySummaryPublisherError {
            switch error {
            case .sourceRejected:
                // 理论上到不了这里（上面已经先仲裁过一次），留着是为了穷尽分支。
                writeError(error.localizedDescription + "上一份日报保持不变。")
                return 3
            case .staleForThisRun:
                // 也不是错误：这份载荷不是本次运行写的，或者已经有更新的发布过了。
                print(error.localizedDescription)
                return 0
            case .emptyPayloadWouldEraseCurrentBrief:
                // **不是错误**：这次确实没有新邮件，保留上一份日报才是正确行为。
                // 退出码必须是 0——提示词告诉 agent「非 0 表示载荷被拒绝，要在输出里
                // 报错」，这里报错只会让 agent 以为自己搞砸了然后去重试。
                print(error.localizedDescription)
                return 0
            }
        } catch {
            writeError("Gmail 日报写入失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// `reloadTimelines` is fire-and-forget. In command-line ingest mode the app
    /// exits immediately, so keep its run loop alive until WidgetCenter has
    /// completed a subsequent round trip (or the safety timeout expires).
    static func flushWidgetCenterRequests(timeout: TimeInterval = 2) {
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
