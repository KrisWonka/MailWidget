// MailSummaryAutomationInstaller.swift
// 契约 12 —「每日自动总结」：把 `MailWidget --summarize <scopeID>` 装成每天定时跑一次
// 的 launchd job。机制照抄 DailySourceInstaller §9.2（写文件 → launchctl bootstrap →
// launchctl print 校验，已存在先 bootout 再 bootstrap 保持幂等），直接复用它导出的
// write/backup/run/runnerScript/launchAgentPlist 五个辅助——不重新实现一份
// "写文件 + 3 次重试脚本 + launchd plist XML + bootstrap/校验"。
//
// 与日报的定时任务刻意分开一个 label（`...mailsummary.claude`），时间点用户可在总结
// 窗口的自动化面板里改——两条 launchd job 各自独立生死，装一个不影响另一个，也不共用
// DailySourceInstaller 那份 prompt/cursor 文件契约（总结走的是 `--summarize <scopeID>`，
// 不是"渲染 prompt 交给外部 agent"那一套）。
//
// 用户反馈（真机验证后）：原来"点按钮直接装、装完显示绿色两行技术性文案"的形态
// 太生硬——改成一个 popover 设置面板（Toggle 开关 + 时间 + 范围 + 保存），配置持久化
// 在 App Group defaults 里，`MailSummaryAutomationSettings` 是这份配置的唯一权威。

import Foundation

/// App Group defaults 里持久化的自动化配置——面板每次打开时读它做初始值，
/// `install(scopeID:hour:minute:)` 成功后写回它（"成功装载的这一份"才算数，
/// 面板里正在编辑、还没保存的草稿不会污染这几个键）。
enum MailSummaryAutomationSettings {
    static let enabledKey = "mailSummaryAutomationEnabled"
    static let hourKey = "mailSummaryAutomationHour"
    static let minuteKey = "mailSummaryAutomationMinute"
    static let scopeIDKey = "mailSummaryAutomationScopeID"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    static var isEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    static var hour: Int {
        get {
            guard let stored = defaults?.object(forKey: hourKey) as? Int, (0...23).contains(stored) else {
                return MailSummaryAutomationInstaller.defaultHour
            }
            return stored
        }
        set { defaults?.set(newValue, forKey: hourKey) }
    }

    static var minute: Int {
        get {
            guard let stored = defaults?.object(forKey: minuteKey) as? Int, (0...59).contains(stored) else {
                return MailSummaryAutomationInstaller.defaultMinute
            }
            return stored
        }
        set { defaults?.set(newValue, forKey: minuteKey) }
    }

    /// nil = 从未成功装载过；面板据此决定用什么当"总结范围"选择器的默认值
    /// （回落到面板打开时总结窗口正在看的 scope）。
    static var scopeID: String? {
        get { defaults?.string(forKey: scopeIDKey) }
        set { defaults?.set(newValue, forKey: scopeIDKey) }
    }

    /// `isEnabled` 键本身不是"真的装着"的权威事实——用户可能在 Finder/终端手动删掉了
    /// plist（或者它因为别的原因消失），这种情况下继续相信一个过期的 true 只会让面板
    /// 显示"已启用"但实际上什么都不会跑。plist 文件是否存在才是唯一权威；每次面板
    /// 打开时校准一次，发现不一致就纠正键值，返回纠正后的真实布尔值。
    @discardableResult
    static func reconcileEnabledWithDisk() -> Bool {
        let fileExists = FileManager.default.fileExists(atPath: MailSummaryAutomationInstaller.plistURL.path)
        if isEnabled != fileExists {
            isEnabled = fileExists
        }
        return fileExists
    }
}

enum MailSummaryAutomationInstaller {

    /// launchd label 固定——这不是"任意 CLI agent"那种可配置出口，只服务总结自动化
    /// 这一条路径。触发时间不再固定，由面板配置、经 `install(scopeID:hour:minute:)`
    /// 的显式参数传入；这两个默认值只在从未配置过时（`MailSummaryAutomationSettings`
    /// 相应键不存在）当兜底。
    private static let label = "com.kris.mailwidget.mailsummary.claude"
    static let defaultHour = 8
    static let defaultMinute = 50

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

    /// 写入 + 装载。`hour`/`minute`/`scopeID` 全部是调用方（自动化面板）当前的草稿值，
    /// 不在这里回读 `MailSummaryAutomationSettings`——面板编辑时间/范围还没点「保存」
    /// 前，这几个键必须继续保持上一次真正成功装载的值，不能被半途的草稿污染；只有这个
    /// 函数成功跑完，草稿才"转正"变成新的权威配置（下面成功路径末尾写回三个键）。
    ///
    /// 抛出的错误直接是 `DailySourceInstaller.InstallError`——它的
    /// `.writeFailed`/`.launchctlFailed` 两个 case 已经带着中文描述，没必要在这里
    /// 再包一层同构的错误类型。失败时不改动 `MailSummaryAutomationSettings` 里已有的
    /// 配置——调用方（`MailSummaryAutomationButton`）会用 `reconcileEnabledWithDisk()`
    /// 重新校准 `isEnabled`，但 hour/minute/scopeID 这三个"上一份成功配置"保持不变。
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

        MailSummaryAutomationSettings.scopeID = scopeID
        MailSummaryAutomationSettings.hour = hour
        MailSummaryAutomationSettings.minute = minute
        MailSummaryAutomationSettings.isEnabled = true

        return DailySourceInstaller.Outcome(
            summary: String(format: "已装载 %@，每天 %02d:%02d 运行", label, hour, minute),
            writtenPaths: [scriptURL.path, plistURL.path]
        )
    }

    /// `install` 的逆操作，Toggle 关闭时调用——不弹二次确认，Toggle 本身已经是明确
    /// 意图。刻意设计成永远"成功"（不 throw）、且对重复调用安全：
    /// - `launchctl bootout` 对本来就没装载的 label 是无害操作，这里不检查它的
    ///   status/output——卸载动作不该因为"其实早就没装着"这种完全正常的情况而报错。
    /// - 两处文件删除都用 `try?`：文件本来就不存在（用户手动删过、或从未成功装载过）
    ///   同样是正常场景，不是错误。
    ///
    /// 这两点合起来的结果是：不管当前真实状态是"已装载"“部分残留”还是"完全没有"，
    /// 调 `uninstall()` 之后都会落到同一个终态（label 未装载、两个文件都不存在、
    /// `isEnabled == false`），不需要调用方先查询"现在到底是什么状态"再决定怎么做。
    @discardableResult
    static func uninstall() -> DailySourceInstaller.Outcome {
        let domain = "gui/\(getuid())"
        DailySourceInstaller.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: scriptURL)

        MailSummaryAutomationSettings.isEnabled = false

        return DailySourceInstaller.Outcome(summary: "已停用每日自动总结", writtenPaths: [])
    }
}
