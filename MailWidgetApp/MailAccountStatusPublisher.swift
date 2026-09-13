// MailAccountStatusPublisher.swift
// MailWidgetApp — 把「Mail.app 里有没有配置真实邮件账户」这个结论，从宿主 app
// 写进 App Group，供 widget extension 只读。
//
// 背景（真机部署实录）：朋友的 Mail.app 一个真实账户都没有（只有本地
// Drafts/Outbox），收件箱 widget 和邮件总结全是空白，且没有任何提示。DataKit 的
// `ProviderProbe.hasConfiguredMailAccounts()` 已经能诊断出这一点，但它直接查
// Envelope Index 的 sqlite 文件——widget extension 是沙盒进程，大概率没有完全磁盘
// 访问权限、读不到 ~/Library/Mail，所以这个判断**不能**放在 extension 里做。这里
// 由宿主 app（有完整磁盘访问权限的那个进程）算好，落一个轻量 Bool 键进 App Group，
// widget 端（`MailWidgetExtension/Views/SharedComponents.swift` 的
// `MailAccountStatusReader`）只读它。
//
// 键名字符串在两个 target 里各自维护一份字面量——`MailWidgetApp/` 和
// `MailWidgetExtension/` 是两个独立编译的 target，DataKit 是唯一横跨两边的共享
// 代码，但这次改动的边界不允许碰 DataKit，只能在两侧各写一份、靠注释互相指认
// （见 `MailAccountStatusReader` 里的 `MailAccountStatusKey`）防止漂移。
//
// 刷新时机：不挂在 `RefreshScheduler`（DataKit 内部类型）的定时 tick 上——那是
// DataKit 内部私有的 Timer，宿主 app 侧拿不到"每次刷新完成"的回调可挂，只能拿到
// `refreshNow()` 这一个显式触发的入口。这里用一个独立的轻量定时器达到类似的
// "随时间推移自愈"效果：这个探测只在用户去邮件 App 增删账户后才会变化，不需要
// 跟 2 分钟级别的邮件刷新对齐，10 分钟自愈一次已经足够及时。
import Foundation

enum MailAccountStatusPublisher {
    /// 必须和 `MailAccountStatusReader.MailAccountStatusKey.hasConfiguredMailAccounts`
    /// （extension 侧，见 `MailWidgetExtension/Views/SharedComponents.swift`）
    /// 完全一致的字符串字面量。
    static let hasConfiguredMailAccountsKey = "hasConfiguredMailAccounts"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    private static var timer: Timer?
    private static let refreshIntervalSeconds: TimeInterval = 10 * 60

    /// 立即探测一次并写回，然后挂一个 10 分钟的自愈定时器。宿主 app 启动
    /// （`AppDelegate.applicationDidFinishLaunching`）时调用一次即可；可重复调用
    /// （幂等——重复调用只会替换掉上一个定时器，不会叠加出多个）。
    static func start() {
        refresh()
        timer?.invalidate()
        let newTimer = Timer(timeInterval: refreshIntervalSeconds, repeats: true) { _ in
            refresh()
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    /// 重新探测一次并写回 App Group。`ProviderProbe.hasConfiguredMailAccounts()`
    /// 要开一次 Envelope Index 的 sqlite 文件查询，丢到后台队列跑，避免在定时器
    /// tick（主线程 RunLoop）或菜单栏"立即刷新"按钮上引入哪怕很小的卡顿——跟
    /// `RefreshScheduler.refreshNow()` 把真正的抓取丢到 `DispatchQueue.global` 同一个
    /// 理由。可以在"用户主动点了刷新"这类点上随手调用，不需要额外节流。
    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let hasAccounts = ProviderProbe.hasConfiguredMailAccounts()
            defaults?.set(hasAccounts, forKey: hasConfiguredMailAccountsKey)
        }
    }
}
