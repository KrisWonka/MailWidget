# DEV_NOTES — MailWidget

跨会话 / 跨工具（Claude、Codex、ChatGPT）共享的项目状态。**改了东西就更新这里，不要只留在对话里。**
本文件不写任何密钥、密码、内网 IP、个人邮箱或 Team ID —— 这个仓库是求职材料，且已刻意去个人化。
`SESSION_LOG.md` 是本仓库**刻意不跟踪**的（见 `.gitignore`），只在本机留存；DEV_NOTES 才是入库的那份。

**Last sync**：2026-09-19 — 日报改为增量 + 结转 + backlog，定时一天三次。（上一次：2026-09-13 — 修掉 launchd 日报任务的三个真机故障（PATH / 工作目录 / 兜底发布），
并把生成脚本的逻辑搬进 DataKit 变成可单测；提示词与显示时区改为跟随运行机器。

---

## 这是什么

macOS 桌面 widget，绑定**本机 Mail.app**（不是 iPhone 镜像的那个系统 widget），四种尺寸，
外加两个附加功能：**Gmail 日报**（外部 AI CLI 每天生成一份决策简报）和**邮件总结**窗口。

架构的硬约束：**widget extension 是沙盒短生命周期进程，读不到 `~/Library/Mail`，也读不到用户环境。**
所以一律是：菜单栏宿主 app 抓取 → 写快照 JSON 进 App Group → `WidgetCenter.reloadAllTimelines()` →
widget 只读渲染。凡是"需要判断系统状态"的逻辑（有没有邮件账户、CLI 能不能用），都必须宿主 app
算好写进 App Group，widget 侧只读结论。

## 构建与安装

```bash
cd /Users/kris/Documents/mail_widget && ./scripts/install.sh     # 构建 + 签名 + 装到 /Applications
cd /Users/kris/Documents/mail_widget && ./scripts/setup.sh       # 面向新机器的一键安装（自动装缺的依赖）
```

Team ID **不写死在仓库里**：`project.yml` 用 `${MAILWIDGET_TEAM_ID}`，由 `install.sh` 探测构建者
自己的签名身份后注入；App Group 由 `$(DEVELOPMENT_TEAM).com.kris.mailwidget` 在构建时展开，
entitlements 和 Info.plist 两边都会展开。**证书 CN 括号里那串不是 Team ID**（Team ID 在 OU 字段）。

测试：`xcodebuild test -project MailWidget.xcodeproj -scheme MailWidget -destination 'platform=macOS'`
当前 109 项，**8 项恒定跳过**（测试 runner 没有完全磁盘访问，读不了 Envelope Index，这是 TCC 边界不是失败）。

## 定时任务的运行契约

两条 launchd job，脚本由 `DataKit/LaunchAgentRunnerScript.swift` 生成：

| Label | 时间 | 干什么 |
|---|---|---|
| `com.kris.gmaildaily.<claude\|codex>` | 09:07 / 09:00 | 外部 AI CLI 读 Gmail → 写载荷 → ingest |
| `com.kris.mailwidget.mailsummary.claude` | 08:50 | `MailWidget --summarize <scopeID>` |

发布链路：agent 原子写 `~/Library/Application Support/GmailDailyWidget/latest.json`
→ `MailWidget --ingest <载荷> --source <源>` 校验并发布进 App Group → widget 读。
`IngestCommand` 的 schema + 邮箱归属校验是**唯一真闸门**；agent 自报的成功不作数。

## ⚠️ 这个仓库最主要的 bug 来源：两条路径漂移

**先读这一节再动手改任何东西。** 2026-09-13 到 09-15 连续三天每天都爆线上 bug，归类之后
几乎全是同一个形状——**同一件事在两条路径上各写了一份，改一处、漏一处**：

| 这件事 | app 内点刷新 | launchd 定时任务 | 爆出来的样子 |
|---|---|---|---|
| PATH 注入 | 早就有 | 漏了 | `env: node: No such file`，`exit 127`，整天没日报 |
| 工作目录钉在 home | 早就有 | 漏了 | codex 沙箱降级只读，载荷写不出来 |
| `--permission-mode auto` | 漏了 | 早就有 | 换台机器就卡死等权限 |
| 关闭 stdin | 早就有 | 漏了 | agent 读 stdin，可能挂住 |
| 发布守门 | 在 Publisher | IngestCommand 另写一份 | 守门被真正的入口绕过 |
| 提示词 / runner 脚本 | 每次实时渲染 | 装任务那刻冻结在磁盘 | 模板层面的修复三周没生效 |

**两条路径是什么**：
- **A** = `DailyRegenerator.regenerate()` → `Process` 起 agent（用户点 ↻ 时走这条）
- **B** = `DailySourceInstaller` 生成 `run-<source>.sh` → launchd 定时执行（每天早上走这条）

**已经做的收敛**（改动前先确认你要改的东西在不在这些地方）：
- `DataKit/AgentInvocation.swift` —— **调起 agent 的命令行唯一定义**（参数、shell 形态、
  source→CLI 映射）。两条路径都从这里取，`Tests/DataKitTests/AgentInvocationParityTests.swift`
  会在两边漂移时当场失败。
- `DataKit/AgentRuntimePath.swift` —— PATH 与 shebang 解释器解析，两条路径共用。
- `DataKit/LaunchAgentRunnerScript.swift` —— B 的脚本生成，可 `bash -n` 单测。
- `DataKit/DailySummaryPublisher.swift` —— 发布的唯一咽喉，`IngestCommand` 已改为调用它。
- `DailySourceInstaller.refreshInstalledArtifacts()` —— **启动时**把已装任务的提示词和
  runner 脚本按当前代码重渲染，解决"生成物冻结在磁盘上"这一类。

**仍未收敛**：暂无。上一轮列的四项已于 2026-09-15 全部收敛：
- 兜底发布的新鲜度判据搬进 `DailySummaryPublisher.freshnessDecision`，脚本改为把本次尝试
  的起始时刻经 `--ingest --not-before <unix>` 交上去，不再自己判。
- 看门狗 / 重试次数 / 重试间隔收进 `AgentRunPolicy`（原先 app 内 14 分钟、脚本 20 分钟，
  没有统一依据）。
- CLI 预检补进脚本（跑一次 `--version`，起不来直接退出，不进重试循环）。
- 「生成中」标志改由两条路径共写同一个键（脚本经 `MailWidget --daily-run start|end`，
  `trap ... EXIT` 保证异常退出也清得掉）。这条的要害不是显示，是**互斥**：早上 9 点任务
  正在跑时用户点 ↻，原先 `guard !isRegenerating()` 看不到它，会并发起第二个 agent。

**动手前的固定检查**：你要改的行为，B 那条路径上对应的位置在哪？没有对应位置就说明它
漏了。加不了共用定义时，至少加一条 parity 测试。

## 多日模拟：改日报相关的任何东西，它必须全绿

`Tests/DataKitTests/DailyBriefSimulationTests.swift`，随 `xcodebuild test` 一起跑，不用单独记。

**为什么有它**：09-13 到 09-19 连续四次线上 bug，每一次"跑一次对不对"都是对的、单元测试全绿；
坏的都是**时间一长、同一个操作做两次**才出现的行为。这个模拟把一周的真实使用快进演一遍
（假邮箱、假时钟、按提示词契约办事的假 agent），走的是**生产环境同一段发布代码**
（`DailySummaryPublisher.publishCore`），每一轮之后检查四条规则：
没办完的事不能消失 / 过期或办完的不能还挂着 / 不超过 6 条 / 被挤掉的不能比留下的更要紧。

**它有牙，已用变异测试证明**（故意弄坏产品代码，看它能不能抓到）：
- 发布时不写镜像 → 抓到，精确指出「9/14 13:07 Debbie 和牙科保险消失了」
- 拿掉零条目守门 → 抓到（靠"不听话的 agent"——守门是防 agent 犯错的，只用听话的假 agent
  时守门从没被触发，第一版就漏了这一条）
- 换回 09-19 之前的旧契约 → 抓到，恰好在周一 13:07

**它测不了的**：AI 判断错了哪封重要；换一台机器从零安装的环境问题（09-13、09-15 那类）。
**假 agent 与提示词的对应**：假 agent 实现的每条规则，`CarryForwardTests` 都断言提示词里
确有对应条款——改提示词时两边一起改。

**隔离**：全部在临时目录里跑，不碰真实 widget 数据。唯一的坑是校验会在"未配置邮箱"时
把载荷邮箱**自动写进真实配置**，所以模拟只用已配置的邮箱，读不到就跳过。

## 真机教训（每一条都是线上故障，不要"优化"掉）

**launchd 环境与 app 进程环境不是一回事** —— 下面四条同源，都是"app 内那条路径早已修过、生成
launchd 脚本时漏了"：

1. **PATH**：launchd 不给 job 继承登录 shell 环境。CLI 写绝对路径**不够** —— npm 装出来的 CLI 是
   `#!/usr/bin/env node` 的壳，**解释器本身仍要走 PATH 去找**，找不到就 `exit 127`
   （`env: node: No such file or directory`）。静态候选目录覆盖不了 nvm/volta 的版本化安装，
   所以 `AgentRuntimePath` 在**安装时**解析一次 shebang 解释器的真实位置，钉进脚本。
2. **工作目录**：launchd 的 cwd 是 `/`，而 **codex 按 cwd 推导沙箱策略** —— cwd 为 `/` 时降级成
   `sandbox: read-only`，载荷根本写不出来（`patch rejected: writing is blocked by read-only sandbox`）；
   cwd 钉在 home 时是 `workspace-write [workdir, /tmp, $TMPDIR]`。脚本必须 `cd "$HOME"`。
3. **兜底发布不能看 agent 的退出码**：实测过 agent 完整写好载荷后在收尾步骤（写游标）撞上 API 额度
   上限而 `exit 1`，一份可用的日报被整个丢掉。判据改成"**本次尝试**有没有写出新载荷"
   （mtime ≥ 尝试起始时刻），比原先的"20 分钟窗口"更精确，也不会重复发布上一次的残留。
4. **agent 会谎报发布成功**：headless 模式下可能拿不到执行命令的权限，却在输出里声称
   "ingest 退出码 0，已发布"。脚本层自己跑一遍 ingest 不经过任何权限系统，是确定性的。

4. **「显示等待」和「进程还活着」是两件事，不能合成一个布尔值。** widget 的「生成中」
   该在**日报落地那一刻**结束（`awaitingBriefSince`，判据是 `lastIngestAt >= startedAt`），
   而防重入和看门狗必须撑到**进程真正退出**（`isRegenerating`）。实测两者差 25–28 秒——
   agent 发布完还要写游标、打运行总结。合并的话只能二选一：要么 widget 白挂半分钟，
   要么用户能在前一个 agent 还活着时点出第二个并发 agent。
5. **看门狗超时必须严格小于 flag 的过期时间**，维持不变式「flag 过期 ⇒ 进程已被杀死」。
   杀的时候注意 `Process` 默认不给子进程单独开进程组，无条件 `kill(-pgid)` 会把宿主
   app 自己一起杀掉——只在子进程自成一组（`pgid == pid`）时才按组杀。

6. **日报是增量检索 + 结转，不是「每轮整份替换」。** 原先每轮只看游标之后的新邮件、再
   整份替换旧日报，于是（a）刷新一次，还没到期的事项会被新邮件挤掉；（b）多跑几次只会
   更糟，每次都清成"上次之后到的那几封"；（c）只能一天跑一次，白天到的邮件要等到第二天。
   现在每轮读 `published.json`（发布层写的镜像，agent 可读；App Group codex 进不去）
   和 `backlog.json`（上一轮被 6 条上限挤掉的），保留仍有效的、剔掉已办完/已过期的，
   再合并新邮件。**被挤掉的必须写回 backlog**——否则它的邮件在游标之前、又不在已发布
   那份里，永远回不来（实测：9/30 截止的牙科保险就这么丢过一次）。结转落地后才把定时
   从一天一次改成 9:07 / 13:07 / 18:07（`AgentRunPolicy.dailyBriefTimes`）。

7. **日报里的每条事实必须出自本轮读到的邮件，结转时必须重新对照原文。** 2026-09-19 实录：日报写
   「Rackham 全日制要 9 学分以上，还没补课的话周一前加上」——邮件里没有任何一封这么说。「9+」出自
   用户自己发给国际中心的**提问**，国际中心只回了个链接；官网实际是研究生 8 学分即全日制。agent 把
   用户的问题当成了官方结论，还给出会让人去加一门不需要的课的建议；之后每轮结转原样搬运。同一份里
   还有一处「会员号尾号 7649」，全部邮件里一次都没出现过。**结转放大了这类错误**：以前每轮从邮件
   重新生成，现在错一次就会一直挂着——所以提示词要求结转前重读原邮件、重建 detail。提示词新增
   「Accuracy」一节；`GroundingTests` 钉住条款。

**其它**：

- **`hostExecutableURL` 只接受 `MailWidget.app` 内部的可执行文件** —— 曾经用临时 harness 二进制装了
  定时任务，渲染进提示词的 ingest 命令指向那个 harness，agent 老老实实执行了一个忽略 `--ingest`
  且返回 0 的程序，日报静默不更新好几天。
- **`DailySummaryPromptTemplate.body` 必须是 `static var`**，`static let` 会把插值冻结在首次访问，
  之后才配置的邮箱永远出不来。
- **时区跟随运行机器**（`localTimeZoneIdentifier`）。曾写死 `America/New_York`，第二台机器在太平洋
  时区，日报一直按早 3 小时判断"今日必办"。生成端跟随了，**显示端（widget / 详情窗）也必须跟随**。
- **Claude 用 `--permission-mode auto`，绝不用 `--allowedTools`** —— 后者是白名单语义，会把 Gmail MCP
  连接器工具一并挡掉，日报的核心步骤反而跑不了。
- **每次尝试包 20 分钟看门狗**，用 `set -m` + `kill -TERM -- -$pid`（负号 = 整个进程组）收子孙进程；
  macOS 没有 `/usr/bin/timeout`，`perl alarm+exec` 杀不掉 fork 出来的子孙。
- **Codex 的 Gmail 是 plugin + app connector（`codex_apps/gmail.*`），`codex mcp list` 里根本不出现。**
  用它判断"有没有连 Gmail"会得到假阴性 —— 查 `~/.codex/config.toml` 里的 `gmail@openai` 条目。
- **Envelope Index 的两处 schema 修正**：`message_global_data.message_id == messages.message_id`
  （不是 ROWID）；Gmail 类账户的邮件存在 All Mail，INBOX 归属只在 `labels` 表里。
- **macOS 会把每个 widget `Link` 的 URL（含 `message://`）投给宿主 app 的 kAEGetURL 处理器**，而
  SwiftUI `MenuBarExtra` 会吞掉 `application(_:open:)`，必须手动用 `NSAppleEventManager` 注册 `'GURL'`
  （`kInternetEventClass`/`kAEGetURL` 常量在新 SDK 里没有，得自己算四字符码）。
- **LSUIElement 后台 app 必须显式激活 Mail**（`NSRunningApplication.activate()` /
  `OpenConfiguration.activates = true`），否则窗口开在后面。
- **bash 3.2**（macOS 自带）没有 `mapfile`/`readarray`，脚本里别用。
- **widget 里表达「进行中」用 `Text(_:style:.timer)`**，由 WidgetKit 自己走字，不需要重建
  timeline。曾有注释断言"widget 不支持动画，静态文案是唯一办法"，是错的。这条路径一次
  真实运行 4–5 分钟，五分钟盯着纹丝不动的「生成中…」，唯一合理的推断就是它死了——
  2026-09-14 用户报的正是这个，而后台其实在正常工作。
- **改 header 必须实际渲染一遍再提交**（329pt 宽，medium/large 同宽）。加计时器时实测
  「生成中 14:59」+ 日期会把标题截成「Gmail…」；解法是生成中时隐藏日期——那是**上一份**
  日报的时间，马上要被替换，是这排里最没用的元素。用 `ImageRenderer` 按真实字体和宽度
  渲染最坏值即可，不要靠估。

## 分发给第二台机器

仓库目前是**私有**，对方 `git pull` 不了。已验证可用的绕行路径（不需要改可见性）：

```bash
# 在本机跑
cd /Users/kris/Documents/mail_widget && git bundle create /tmp/update.bundle <对方的HEAD>..main
scp /tmp/update.bundle <对方>:/tmp/update.bundle
# 在对方机器跑
cd ~/Documents/MailWidget && git pull /tmp/update.bundle main
```

**SSH 会话里签不了 bundle**：`codesign` 对单个 Mach-O 可以，对 `.app`/`.appex` 一律
`errSecInternalComponent`，解锁钥匙串 + `security set-key-partition-list` 都不够。
可行做法是把构建放回对方的 GUI 会话：

```bash
sudo launchctl asuser <uid> sudo -u <user> /bin/bash -lc "cd <repo> && ./scripts/install.sh"
```

## 未决

- **仓库可见性未定**：仍是私有。切 public 前注意历史里有 2 个提交含旧的个人 Gmail、4 个含 Team ID，
  需要 `git filter-branch` 重写并 force-push（force-push 会被安全策略拦，只能由本人执行）。
- **review 批次 2/3 未做**：Medium 档（`mailwidget://` capability token、权限被撤销时的可见性、
  刷新间隔立即生效、`openMessage` 死代码、快照 chmod 与备份排除）+ 测试审查员的 10 项 backlog。
