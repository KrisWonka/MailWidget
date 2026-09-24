// AgentInvocation.swift
// 「怎么调起一个 agent」的唯一权威定义。
//
// 为什么必须单独成文件：这个项目连续三天每天都爆 bug，归类之后**几乎全是同一个形状**——
// 同一件事在两条路径上各写了一份，改一处、漏一处：
//
//   | 这件事              | app 内点刷新            | launchd 定时任务        | 结果            |
//   |---------------------|------------------------|------------------------|-----------------|
//   | PATH 注入           | 早就有                  | 漏了                    | exit 127，整天没日报 |
//   | 工作目录钉在 home    | 早就有                  | 漏了                    | codex 降级只读，写不出载荷 |
//   | --permission-mode   | 漏了                    | 早就有                  | 换台机器就卡死   |
//   | 关闭 stdin          | 早就有                  | 漏了                    | agent 可能等输入挂住 |
//   | 发布守门            | 在 Publisher            | IngestCommand 另写一份   | 守门被绕过       |
//   | 提示词更新          | 每次实时渲染             | 装任务那刻冻结          | 模板修复三周没生效 |
//
// 六次里有五次是"两份实现漂移"，不是"想错了"。所以正确的修法不是再打一个补丁，而是**把
// 两条路径真正要共用的东西收敛成一个定义**，并且用测试钉住"两边必须一致"。
//
// 这个文件负责其中最要命的一项：**调起 agent 的命令行**。此前 codex 和 claude 的参数在
// `DailyRegenerator.arguments(for:prompt:)` 和 `DailySourceInstaller.installXxxJob` 里各写
// 了一份互不相干的字符串字面量——`--permission-mode auto` 那个 bug 就是这么来的：2026-08-25
// 它被加进 launchd 那一份，另一份从功能引入起就没动过，直到 2026-09-14 才发现。

import Foundation

enum AgentInvocation {
    /// 除提示词以外的全部参数。**两条路径都必须从这里取**，不许各自拼字符串。
    ///
    /// - codex：`exec` 是子命令；`--skip-git-repo-check` 必需——宿主 app / launchd 的工作
    ///   目录不是 git 仓库，codex 默认的受信目录检查会直接拒绝执行（真机首跑实测命中）。
    /// - claude：`-p` 是 headless；`--permission-mode auto` 让模型分类器就地批准/拒绝权限
    ///   询问。**不能用 `--allowedTools`**，那是白名单语义，会把 Gmail MCP 连接器一并挡掉，
    ///   日报的核心步骤反而跑不了。`default` 模式会等一个不存在的人点「允许」——2026-08-25
    ///   那次 launchd 任务卡死近 3 小时就是它。
    static func flags(for source: String) -> [String] {
        switch source {
        case DailySource.codex:
            return ["exec", "--skip-git-repo-check"]
        default:
            return ["-p", "--permission-mode", "auto"]
        }
    }

    /// 来源 ID → 具体 CLI。同样是两条路径都要用的东西，收在一处。
    static func cli(for source: String) -> AgentCLI? {
        switch source {
        case DailySource.codex:
            return .codex
        case DailySource.claude:
            return .claude
        default:
            return nil
        }
    }

    /// `Process.arguments` 用的形态：参数 + 提示词正文（位置参数）。
    static func arguments(for source: String, prompt: String) -> [String] {
        flags(for: source) + [prompt]
    }

    /// launchd runner 脚本用的形态。提示词太长不能直接塞进命令行，落成文件后用
    /// `$(cat …)` 注入；`promptFileExpression` 由调用方替换成加好引号的真实路径。
    ///
    /// **`< /dev/null` 不是可选项**：`DailyRegenerator` 那条路径早就用
    /// `standardInput = FileHandle.nullDevice` 显式关掉了 stdin，注释写明"真机首跑实测
    /// codex 会等额外的 stdin 输入，继承了打开的管道就会挂起/误读"。脚本这条一直没关，
    /// 第二台机器的日志里能看到 codex 打出 `Reading additional input from stdin...`。
    static func shellCommand(
        executablePath: String,
        source: String,
        promptFileExpression: String
    ) -> String {
        let flagText = flags(for: source).joined(separator: " ")
        return "\"\(executablePath)\" \(flagText) \"$(cat \(promptFileExpression))\" < /dev/null"
    }
}

/// 跑一次 agent 的策略参数。和 `AgentInvocation` 同理：这些数值原先散在两条路径上
/// 各写一份（app 内 14 分钟看门狗、launchd 脚本 20 分钟 `sleep 1200`），没有任何统一依据，
/// 纯粹是各自随手定的。收在一处，改一次两边都动。
enum AgentRunPolicy {
    /// 「重新生成中」这个标志多久算过期。widget 靠它判断要不要显示进行中状态，
    /// 两条路径也靠它互斥（见 `unattendedMarksRegenerating` 的说明）。
    static let staleAfter: TimeInterval = 15 * 60

    /// 进程看门狗超时。**必须严格小于 `staleAfter`**，维持不变式：
    ///
    ///     标志已过期 ⇒ 上一次的 agent 进程一定已经被杀死
    ///
    /// 没有这条不等式，防重入判据就只是时间判断、跟进程死活无关：一次跑满 15 分钟的运行
    /// 会让标志先过期，用户再点一次就并发起第二个 agent，两个一起往同一个 latest.json 写、
    /// 各自推进游标。
    ///
    /// 14 分钟对真实运行是宽裕的：本机实测三次分别 4:00 / 4:49 / 4:46。
    static let watchdogTimeout: TimeInterval = staleAfter - 60

    /// 无人值守（launchd）时的重试次数。**app 内点刷新刻意不重试**——那条路径用户就在
    /// 跟前，失败了他自己会再点，静默重试反而让他等更久且看不出发生了什么；定时任务没人
    /// 看着，一次网络抖动就整天没有日报，所以要重试。
    static let unattendedRetryCount = 3

    /// 两次重试之间的间隔（秒）。
    static let unattendedRetryDelay = 60

    /// 日报定时任务每天在哪几个时刻跑。
    ///
    /// 原先一天只跑一次（9:07 / 9:00）。2026-09-19 用户报「mailwidget 又不更新了」：widget
    /// 上那份停在前一天 00:39，而 Gmail 里已经到了 14 个新线程、好几个标了 IMPORTANT——
    /// 9:07 那轮查的时候它们还没到，要等第二天早上才会被看到。一份整天不动的"日报"
    /// 和坏了没有区别。
    ///
    /// **多跑几次之所以现在才安全**：此前每轮都用"游标之后的新邮件"整份替换旧日报，
    /// 一天跑三次就等于每几小时清空一次待办。结转（见提示词检索第 5 步）落地之后，
    /// 每轮都是"仍有效的旧事项 ∪ 新邮件"，多跑只会更新、不会丢。
    ///
    /// claude 与 codex 错开 7 分钟、都避开 8:50 的邮件总结任务，免得同时抢 launchd 或
    /// 撞见彼此的日志。
    /// App Group 里的时间表覆盖项。存成 `["09:00", "13:00"]` 这样的字符串数组。
    ///
    /// 为什么必须做成可配置而不是直接去改 plist：`refreshInstalledArtifacts()` 每次 app 启动
    /// 都会把 plist 按这里的返回值刷回去（那是为了让代码里的时间表能到达已装好的机器）。
    /// 手工改过的 plist 下一次开 app 就被覆盖——正是"生成物冻结在磁盘上"那个坑的反面。
    static let scheduleOverrideKey = "dailyBriefSchedule"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedConstants.appGroupIdentifier)
    }

    static func dailyBriefTimes(for source: String) -> [(hour: Int, minute: Int)] {
        if let override = defaults?.stringArray(forKey: scheduleOverrideKey),
           let parsed = parseSchedule(override) {
            return parsed
        }
        let minute = source == DailySource.codex ? 0 : 7
        return [(9, minute), (13, minute), (18, minute)]
    }

    /// `"09:00"` / `"9:00"` → `(9, 0)`。任何一项不合法就整体作废、退回默认时间表——
    /// 宁可按默认跑，也不要因为一个写坏的配置让日报一天都不跑。
    static func parseSchedule(_ values: [String]) -> [(hour: Int, minute: Int)]? {
        guard !values.isEmpty else { return nil }
        var times: [(hour: Int, minute: Int)] = []
        for value in values {
            let parts = value.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute)
            else { return nil }
            times.append((hour, minute))
        }
        return times.sorted { $0.hour * 60 + $0.minute < $1.hour * 60 + $1.minute }
    }

    /// 写入覆盖项；传 nil 清除、退回默认。写完立刻落盘——调用方是个写完就 `Darwin.exit`
    /// 的子命令，来不及等异步刷盘（2026-09-15 `--daily-run` 踩过同一个坑）。
    static func setScheduleOverride(_ values: [String]?) {
        if let values { defaults?.set(values, forKey: scheduleOverrideKey) }
        else { defaults?.removeObject(forKey: scheduleOverrideKey) }
        defaults?.synchronize()
    }
}

