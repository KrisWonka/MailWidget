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
