// LaunchAgentRunnerScript.swift
// 日报 / 邮件总结那两条 launchd 定时任务实际执行的 shell 脚本，由这里生成。
//
// 为什么单独成文件、又放在 DataKit：这段脚本在真机上连续藏过三个 bug，全都是"在 app
// 进程里跑得好好的逻辑，换到 launchd 里就不成立"——
//   1. PATH：launchd 不给 job 继承登录 shell 环境，npm 装的 CLI（`#!/usr/bin/env node`）
//      连解释器都找不到，`exit 127`；
//   2. 工作目录：launchd 的 cwd 是 `/`，codex 据此把沙箱降级成 read-only，日报载荷写不出来；
//   3. 兜底发布被锁在「agent 退出码为 0」的分支里，结果一份已经写好的完整日报，因为 agent
//      在最后一步撞上额度限制而被整个丢掉。
// 三处都是"生成出来的文本"层面的缺陷，而它原先长在 MailWidgetApp target 里，单元测试
// （DataKitTests）够不着，只能等真机故障暴露。搬到 DataKit 后可以直接 `bash -n` 校验语法、
// 逐行断言关键约束。

import Foundation

enum LaunchAgentRunnerScript {
    /// 重试是为了覆盖 Gmail 连接器 tools fetch 的偶发超时——实测 `claude mcp list`
    /// 连续两次调用就出现过一次超时。无人值守的任务不能因为一次抖动就整天没有日报。
    /// `fallbackIngest` 是发布环节的兜底：agent 在 headless 模式下**可能拿不到执行
    /// 命令的权限**，却仍在自己的输出里声称"ingest 退出码 0，已发布"（2026-08-25 实录：
    /// staging 载荷写到了 13:23，App Group 却停在前一天，游标还自报 published）。
    /// 脚本自己跑一遍 ingest 不经过任何权限系统，是确定性的；只在 staging 载荷确实是
    /// **本次尝试**写出来的（mtime 不早于这次尝试的起始时刻）时才执行，避免把陈旧载荷
    /// 盖到更新的发布上。
    ///
    /// 它刻意**不看 agent 自己的退出码**：2026-09-13 真机实录，codex 完整检索、把载荷
    /// 原子写好之后，在写游标那一步撞上 ChatGPT 额度上限而 `exit 1`——原先兜底发布被锁在
    /// `status -eq 0` 分支里，于是一份已经写好且完整的日报被整个丢掉，widget 又空一天。
    /// 载荷本身的合法性由 `IngestCommand` 校验（schema + 邮箱归属），那才是真正的闸门；
    /// 退出码非零只说明 agent 的某个步骤没走完，不等于它写出的载荷不可用。
    ///
    /// 每次尝试都包了一层 20 分钟（1200s）看门狗，直接对应 2026-08-25 那次实录
    /// （09:23 启动、12:17 才结束，近 3 小时）——`--permission-mode auto`（见
    /// `installClaudeJob`）已经从源头堵死"等一个不存在的人点允许"这条卡死路径，这层
    /// 超时是第二道保险：万一还有别的原因卡住（网络挂起、MCP 连接器无响应等），也不能
    /// 让单次尝试吃掉一整个白天。
    ///
    /// 选择"后台 PID + kill"而不是 `perl -e 'alarm shift; exec @ARGV'`：macOS 没有
    /// `/usr/bin/timeout`（已用 `ls` 实测确认不存在），perl 版能杀掉被 exec 替换的那
    /// 一个进程，但 `claude -p` 会在权限询问、Bash 工具调用等场景 fork 出子进程——
    /// `alarm`+`exec` 的 SIGALRM 只送到 exec 出来的那一个进程，杀不到它自己再 fork
    /// 出来的子孙，会留下孤儿进程继续跑。这里改用 `set -m` 开启 job control 让每个
    /// 后台任务拿到独立进程组，超时后 `kill -TERM -- -$pid`（负号 pid = 整个进程组）
    /// 连子孙一起收，5 秒宽限期后 `kill -KILL` 兜底。已用两个最小复现脚本验证过：
    /// (1) `sleep 10` 在 3 秒超时下确实提前终止、返回非零状态，脚本据此判定失败并进入
    /// 重试；(2) 故意 fork 一个孙进程验证它也被杀死，不是只砍了直接子进程。
    static func make(
        command: String,
        executablePath: String? = nil,
        markerCommand: String? = nil,
        fallbackIngest: (payloadPath: String, command: String)? = nil
    ) -> String {
        // CLI 可用性预检。app 内那条路径开跑前会调 `AgentCLILocator.unusableReason` 真的
        // 探一次（真机实录：codex 0.137 文件在、一跑 `exec` 就因模型版本不兼容崩溃），
        // 脚本这边一直没有——坏 CLI 会让定时任务白跑满三轮重试。这里用最轻的等价物：
        // 先跑一次 `--version`，起不来就直接报错退出，不进重试循环。
        let preflightBlock = executablePath.map { path in
            """

            if ! "\(path)" --version > /dev/null 2>&1; then
              echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] \(path) 跑不起来（--version 失败），跳过本次运行"
              exit 1
            fi
            """
        } ?? ""

        // 「生成中」标志：让 widget 在定时任务跑的时候也有进行中提示，更要紧的是让它与
        // app 内的「立即刷新」互斥（同一个 App Group 键）。`trap` 保证异常退出也会清掉。
        let markerBlock = markerCommand.map { command in
            """

            \(command) start 2>/dev/null || true
            trap '\(command) end 2>/dev/null || true' EXIT
            """
        } ?? ""

        let pathExport = AgentRuntimePath.exportStatement(
            extraDirectories: executablePath.map(AgentRuntimePath.directoriesNeeded(toRun:)) ?? []
        )
        let ingestBlock = fallbackIngest.map { ingest in
            """

              if [ -f "\(ingest.payloadPath)" ]; then
                echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] 兜底发布（把本次尝试的起始时刻交给 --not-before 判定）"
                if \(ingest.command) --not-before "$attempt_started"; then
                  exit 0
                fi
                echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] 兜底发布失败"
              fi
            """
        } ?? ""

        return """
        #!/bin/bash
        # 由 MailWidget 生成。手工改动会在下次"一键添加"时被覆盖（改动前会自动备份）。
        set -uo pipefail
        # launchd 不给 job 继承登录 shell 的环境，PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`。
        # 把 CLI 写成绝对路径还不够——npm 装出来的 CLI 是 `#!/usr/bin/env node` 的壳，
        # **解释器自己要走 PATH 去找**，找不到就 `exit 127`（2026-09-13 真机实录：
        # `env: node: No such file or directory`，三次重试全挂，widget 停在前一天）。
        \(pathExport)
        # launchd 把 job 的工作目录设在 `/`，而 codex **按工作目录推导沙箱策略**：cwd 是 `/`
        # 时它降级成 `sandbox: read-only`，于是日报载荷根本写不出来（2026-09-13 真机实录：
        # `patch rejected: writing is blocked by read-only sandbox`）。cwd 钉在 home 时
        # banner 变成 `sandbox: workspace-write [workdir, /tmp, $TMPDIR]`，`~/Library/...`
        # 落在可写范围内。`DailyRegenerator` 早就为同一原因把 cwd 钉在了 home
        # （`currentDirectoryURL = NSHomeDirectory()`），这里补齐同样的处理。
        cd "$HOME" || exit 1
        # 开 job control：让下面每个 `( ... ) &` 后台任务拿到独立进程组，超时时才能用
        # `kill -TERM -- -$pid` 把它和它 fork 出来的子孙一并收掉，而不是只砍直接子进程。
        set -m
        \(preflightBlock)\(markerBlock)
        for attempt in $(/usr/bin/seq 1 \(AgentRunPolicy.unattendedRetryCount)); do
          echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] attempt ${attempt}/\(AgentRunPolicy.unattendedRetryCount)"
          # 兜底发布用它判断「这份载荷是不是本次尝试写的」——比原先的"20 分钟内"窗口精确，
          # 也不会把上一次尝试留下的载荷重复发布。
          attempt_started=$(/bin/date +%s)

          ( \(command) ) &
          cmd_pid=$!
          (
            /bin/sleep \(Int(AgentRunPolicy.watchdogTimeout))
            if /bin/kill -0 "$cmd_pid" 2>/dev/null; then
              echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] attempt ${attempt}/\(AgentRunPolicy.unattendedRetryCount) 已跑满 \(Int(AgentRunPolicy.watchdogTimeout / 60)) 分钟，判定挂死，终止进程组 -$cmd_pid" >&2
              /bin/kill -TERM -- -"$cmd_pid" 2>/dev/null
              /bin/sleep 5
              /bin/kill -KILL -- -"$cmd_pid" 2>/dev/null
            fi
          ) &
          watchdog_pid=$!

          status=0
          wait "$cmd_pid" || status=$?
          /bin/kill "$watchdog_pid" 2>/dev/null
          wait "$watchdog_pid" 2>/dev/null

          if [ "$status" -eq 0 ]; then
            echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] ok"
          fi
        \(ingestBlock)
          if [ "$status" -eq 0 ]; then
            exit 0
          fi
          echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] failed (exit ${status}), retrying in \(AgentRunPolicy.unattendedRetryDelay)s"
          /bin/sleep \(AgentRunPolicy.unattendedRetryDelay)
        done

        echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] giving up after \(AgentRunPolicy.unattendedRetryCount) attempts"
        exit 1
        """
    }
}
