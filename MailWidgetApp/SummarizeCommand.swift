// SummarizeCommand.swift
// 契约 12 — 宿主 app 的命令行入口：`MailWidget --summarize <scopeID>`，同步跑一次
// 邮件总结并退出，不进 GUI。
//
// 与 IngestCommand 同一先例：在 SwiftUI 建立任何 Scene 之前处理完、进程直接
// exit，不拉起菜单栏图标、不启动 RefreshScheduler，不干扰已经在跑的常驻实例。
// launchd 自动化脚本（`MailSummaryAutomationInstaller`）和 widget 按钮触发的
// 生成走的是同一个 `MailSummarizer.summarize(scopeID:)`——契约 12「widget 按钮
// 与自动化共用实现」。
//
// 退出码：0 成功 / 1 生成失败 / 2 参数用法错误。`MailSummarizer.summarize` 本身
// 是同步、分钟级的调用（AppleScript 抓信 + 起 claude 子进程等它跑完），CLI 场景
// 下就是要阻塞到跑完为止，不需要 IngestCommand 那种 WidgetCenter round-trip
// 等待——`summarize` 内部负责校验、落盘与失败时的 lastError 记录。
import Foundation

enum SummarizeCommand {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let flagIndex = arguments.firstIndex(of: "--summarize") else {
            return nil
        }
        guard arguments.indices.contains(flagIndex + 1) else {
            writeError("用法：MailWidget --summarize <scopeID>")
            return 2
        }

        let scopeID = arguments[flagIndex + 1]
        let succeeded = MailSummarizer.summarize(scopeID: scopeID)
        return succeeded ? 0 : 1
    }

    private static func writeError(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}
