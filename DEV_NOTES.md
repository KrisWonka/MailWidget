# DEV_NOTES — MailWidget

跨会话 / 跨工具（Claude、Codex、ChatGPT）共享的项目状态。**改了东西就更新这里，不要只留在对话里。**
本文件不写任何密钥、密码、内网 IP、个人邮箱或 Team ID —— 这个仓库是求职材料，且已刻意去个人化。
`SESSION_LOG.md` 是本仓库**刻意不跟踪**的（见 `.gitignore`），只在本机留存；DEV_NOTES 才是入库的那份。

**Last sync**：2026-09-13 — 修掉 launchd 日报任务的三个真机故障（PATH / 工作目录 / 兜底发布），
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
