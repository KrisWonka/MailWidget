// MailSummaryAutomationInstaller.swift
// 契约 12 —「添加每日自动化」：把 `MailWidget --summarize <scopeID>` 装成每天 08:50
// 跑一次的 launchd job。机制照抄 DailySourceInstaller §9.2（写文件 → launchctl
// bootstrap → launchctl print 校验，已存在先 bootout 再 bootstrap 保持幂等），直接
// 复用它导出的 write/backup/run/runnerScript/launchAgentPlist 五个辅助——不重新
// 实现一份"写文件 + 3 次重试脚本 + launchd plist XML + bootstrap/校验"。
//
// 与日报的定时任务刻意分开一个 label（`...mailsummary.claude`）和一个时间点
// （08:50，日报常见 09:07，错开跑，互不抢起点）——两条 launchd job 各自独立生死，
// 装一个不影响另一个，也不共用 DailySourceInstaller 那份 prompt/cursor 文件契约
// （总结走的是 `--summarize <scopeID>`，不是"渲染 prompt 交给外部 agent"那一套）。

import Foundation

enum MailSummaryAutomationInstaller {

    /// launchd label 与触发时间固定成一个值——这不是"任意 CLI agent"那种可配置出口，
    /// 只服务 widget 按钮触发的这一条路径，用户没有理由要挑时间或换 agent。
    private static let label = "com.kris.mailwidget.mailsummary.claude"
    private static let defaultHour = 8
    private static let defaultMinute = 50

    /// MailWidget.app 打包安装后的绝对路径。CLI 分支（`SummarizeCommand`）读的是
    /// `ProcessInfo.arguments`，跟这里写死的路径无关——这里写死是因为 launchd 启动
    /// 一个进程必须给它一个绝对路径，不能指望继承到任何 PATH。
    private static let appExecutablePath = "/Applications/MailWidget.app/Contents/MacOS/MailWidget"

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// 沿用日报那条 GmailDailyWidget 数据目录，不新开一个——两条自动化本来就是同一个
    /// "定时唤起本 app 一次"家族，用户排查时也习惯去这一个目录看脚本。
    static var scriptURL: URL {
        home.appendingPathComponent("Library/Application Support/GmailDailyWidget/mail-summary-claude.sh")
    }

    static var plistURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        home.appendingPathComponent("Library/Logs/mailwidget-mail-summary.log")
    }

    /// 确认弹窗要展示的内容：两个即将写入的路径 + 触发时间。窗口层先弹确认框，
    /// 用户点「添加」才调 `install(scopeID:)` 真正落盘——这个函数本身不产生任何副作用。
    static func preview() -> (scriptPath: String, plistPath: String, hour: Int, minute: Int) {
        (scriptURL.path, plistURL.path, defaultHour, defaultMinute)
    }

    /// 真正写入 + 装载。`scopeID` 用调用方（总结窗口）当前正在看的那个 scope，原样
    /// 拼进 `--summarize` 的命令行——不做任何校验或转义之外的加工，CLI 入口
    /// （`SummarizeCommand`）和窗口按钮共用同一条 `MailSummarizer.summarize(scopeID:)`
    /// 路径，值得信的 scopeID 早在打开总结窗口那一步就校验过了（契约 12 的
    /// fail-closed 路由）。
    ///
    /// 抛出的错误直接是 `DailySourceInstaller.InstallError`——它的
    /// `.writeFailed`/`.launchctlFailed` 两个 case 已经带着中文描述，没必要在这里
    /// 再包一层同构的错误类型。
    @discardableResult
    static func install(scopeID: String, hour: Int = defaultHour, minute: Int = defaultMinute) throws -> DailySourceInstaller.Outcome {
        let command = "\"\(appExecutablePath)\" --summarize \"\(scopeID)\""

        try DailySourceInstaller.write(DailySourceInstaller.runnerScript(command: command), to: scriptURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        try DailySourceInstaller.backup(plistURL)
        try DailySourceInstaller.write(
            DailySourceInstaller.launchAgentPlist(
                label: label, scriptPath: scriptURL.path, logPath: logURL.path,
                hour: hour, minute: minute
            ),
            to: plistURL
        )

        let domain = "gui/\(getuid())"
        DailySourceInstaller.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let bootstrap = DailySourceInstaller.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        guard bootstrap.status == 0 else {
            throw DailySourceInstaller.InstallError.launchctlFailed(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let check = DailySourceInstaller.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        guard check.status == 0 else {
            throw DailySourceInstaller.InstallError.launchctlFailed("装载后 launchctl print 查不到 \(label)")
        }

        return DailySourceInstaller.Outcome(
            summary: String(format: "已装载 %@，每天 %02d:%02d 运行", label, hour, minute),
            writtenPaths: [scriptURL.path, plistURL.path]
        )
    }
}
