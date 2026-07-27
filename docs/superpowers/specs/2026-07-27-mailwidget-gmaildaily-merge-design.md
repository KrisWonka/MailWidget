# MailWidget × GmailDailyWidget 合并设计

日期：2026-07-27
状态：待评审

## 1. 背景

两个独立的 macOS WidgetKit 项目目前各自运行：

| | GmailDailyWidget | MailWidget |
|---|---|---|
| 仓库 | `~/Documents/General/GmailDailyWidget` | `~/Documents/mail_widget` |
| Bundle ID | `com.kris.GmailDailyWidget` | `com.kris.mailwidget` |
| App Group | `LR8V7939D4.com.kris.GmailDailyWidget` | `LR8V7939D4.com.kris.mailwidget` |
| 宿主形态 | 普通窗口 app，关窗即退出 | `LSUIElement` 菜单栏常驻 |
| 数据来源 | AI 生成的决策简报，外部推送 | 轮询 Apple Mail Envelope Index（2 分钟） |
| 尺寸 | Medium / Large | Small / Medium / Large / ExtraLarge |
| 文案语言 | 中文 | 英文 |
| 安装方式 | `scripts/install.sh` 装到 `/Applications` | Debug 构建后从 DerivedData 直接 open |

日报的生产者是**本地 Codex cron**：`~/.codex/automations/daily-gmail-summary/automation.toml`，
`kind = "cron"`、`execution_environment = "local"`、每天 09:00 America/New_York 触发。它有两条发布路径，
prompt 中硬编码了绝对路径：

1. Widget：写 `~/Library/Application Support/GmailDailyWidget/latest.json`，然后执行
   `/Applications/GmailDailyWidget.app/Contents/MacOS/GmailDailyWidget --ingest <该文件>`
2. Apple Notes（fallback）：写同目录 `latest.html`，然后执行
   `osascript ~/Documents/General/GmailDailyWidget/scripts/update_note.applescript <该 html>`

增量游标持久化在 `~/.codex/automations/daily-gmail-summary/memory.md`。

## 2. 目标

1. 两个 app 合并为一个，MailWidget 作为宿主；桌面上仍是**两个各自独立的 widget**。
2. 两个 widget 视觉风格接近，**不删除任何一方的任何现有要素**。
3. 日报源可在 Codex / Claude 之间切换，在 App 内设置。
4. 能一键把日报定时任务添加到 Codex 或 Claude；也能导出模板，手工接入其它 agent。

## 3. 非目标

- 不合并成单个可切换模式的 widget。两个 widget 永远独立。
- App 不做定时任务的**持续托管**（不轮询、不自动启停、不监控外部调度器状态）。
  App 只做两件事：一次性写入调度配置，以及在 ingest 时仲裁来源。
- 不改 `latest.json` 的 JSON schema。`schemaVersion` 保持 `1`。
- 不在 App 内自建 Gmail OAuth 或日报生成逻辑。生成始终由外部 agent 负责。
- 不改 MailWidget 现有 widget 的任何一行渲染代码（样式 token 抽取除外，见 §6.1）。

## 4. 已确认的决策

| # | 决策 | 备选与否决理由 |
|---|---|---|
| D1 | 一个 App（`com.kris.mailwidget` 为宿主），两个并列独立 widget | 否决"两 app 独立只统一视觉"（达不到合并目标）；否决"单 widget 可切换模式"（两种数据密度差异大，同一版式必然双向妥协，与"不删要素"冲突） |
| D2 | App 做来源仲裁，不托管调度启停 | 否决"App 同时管调度"（App 会成为 Codex 配置的常驻写入方，出错面大） |
| D3 | 视觉向 MailWidget 看齐；MailWidget 不改；语言各自保留 | MailWidget 的背景色是针对 macOS 26+ 玻璃高光调过的，是被验证过的值 |
| D4 | 模板出口 = 剪贴板 + 导出目录 | 否决"预置 Gemini/Cursor/Amp 配置格式"（本机未安装，格式无法实测，写错会静默失效） |

D2 在 §9 有一处受控放宽：App **可以一次性创建**调度任务（用户点按触发），但创建后不再管理。

## 5. 目标架构

以下是**仓库源码布局**（`~/Documents/mail_widget/`），不是 `.app` 包内结构。
产物仍是单个 `MailWidget.app`（`com.kris.mailwidget`，`LSUIElement` 菜单栏常驻），
其中嵌入一个 extension，该 extension 的 WidgetBundle 注册两个 widget。

```
mail_widget/
│
├─ MailWidgetApp/                 菜单栏 + Settings + Onboarding
│   ├─ SettingsView.swift         新增「Gmail 日报」区（§7）
│   └─ DailySourceInstaller.swift 新增：四个调度出口的实现
│
├─ DataKit/                       现有数据层
│   ├─ Models.swift               现有 MailSnapshot 等，不动
│   ├─ DailySummary.swift         从 GmailDailyWidget/Shared 搬入
│   ├─ DailySummaryStore.swift    从 GmailDailyWidget/Shared 搬入
│   ├─ DailySourceSettings.swift  新增：来源仲裁与已知源列表
│   ├─ DailySummaryMigration.swift 新增：旧 App Group 数据迁移
│   └─ WidgetTheme.swift          新增：两个 widget 共享的样式 token
│
├─ MailWidgetExtension/
│   ├─ WidgetBundle.swift         注册两个 widget
│   ├─ Views/                     现有 MailWidget 视图，仅改为引用 WidgetTheme
│   └─ DailyViews/                日报视图，从 GmailDailyWidget 搬入并改样式
│
└─ scripts/
    ├─ install.sh                 从 GmailDailyWidget 移植（§9）
    └─ update_note.applescript    从 GmailDailyWidget 搬入（Codex 的 Notes 路径仍在用）

App Group: LR8V7939D4.com.kris.mailwidget
    ├─ snapshot.json    ← RefreshScheduler 轮询 Apple Mail 写入
    └─ latest.json      ← --ingest 写入
```

数据目录（不属于 App Group，是 agent 与 App 的交接区）保持不变：
`~/Library/Application Support/GmailDailyWidget/`

保持旧路径是刻意的：Codex automation 的 prompt 里这个路径出现多次，不动它可以少改一处、少一处出错机会。

## 6. 视觉统一

### 6.1 共享 token

新建 `DataKit/WidgetTheme.swift`，编译进 extension target。它的初始值**全部取自 MailWidget 当前实现**，
MailWidget 侧改动仅为"把字面量换成 token 引用"，渲染结果逐像素不变：

```swift
enum WidgetTheme {
    static func background(_ scheme: ColorScheme) -> Color   // dark: #0D0D0F, light: .white
    static let paddingMedium: CGFloat = 14
    static let paddingLarge: CGFloat = 16
    static let paddingSmall: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 8
    static let titleFont: Font = .subheadline.weight(.semibold)
    static let bodyFont: Font = .subheadline
    static let metaFont: Font = .caption2
}
```

背景色不能简化为系统色。`MailWidgetView.swift` 的注释记录了原因：macOS 26+ 会在
`.containerBackground` 之上叠加一层无法关闭的镜面/玻璃高光，`#0D0D0F` 是为了让**合成后**的观感落在近黑，
比"真实目标色"更暗是必要的。日报侧套用同一函数即可获得一致底色。

### 6.2 日报侧改动

| 项 | 现状 | 改为 |
|---|---|---|
| 背景 | `.containerBackground(.background, for: .widget)` | `WidgetTheme.background(colorScheme)` |
| 行标题 | `.caption.weight(.semibold)` | `WidgetTheme.titleFont`（`subheadline.semibold`） |
| 行详情 | `.caption2` | `WidgetTheme.metaFont`（值相同，改为引用） |
| padding | Medium 12 / Large 16 | Medium 14 / Large 16 |
| 行间分隔 | `Divider()` | 移除，改用 `rowSpacing: 6` |
| 行数策略 | 固定 3（Medium）/ 6（Large） | `ViewThatFits` 阶梯 |

**`ViewThatFits` 是必需项，不是可选优化。** 行标题从 `caption` 升到 `subheadline` 会增加每行高度，
移除 `Divider` 省下的高度不足以抵消。Medium 仅约 158pt 可用高度，固定 3 行会溢出。阶梯：

- Medium：3 行 → 2 行 → 1 行
- Large：6 → 5 → 4 → 3 → 2 → 1 行

这是**增加**一个 MailWidget 已有的要素，不是删除日报的要素，符合约束。

### 6.3 明确保留的要素

改动后两个 widget 各自的独有要素全部保留，逐项确认：

- MailWidget：未读圆点、未读数大字、翻页按钮与 `MailPageIntent`、mark-all-read 按钮、
  stale 徽标、`ViewThatFits`、Small 与 ExtraLarge 尺寸、`AppIntentConfiguration` 范围选择、英文文案
- 日报：level 色条（5 级配色）、生成时间（固定 America/New_York，`M月d日 HH:mm`）、
  headline（仅 Large 显示）、`[立即]/[今天]/[本周]/[可选]/[知悉]` 五级语义、
  空态与未初始化态两种独立文案、中文文案

日报 widget **不新增**来源标记。来源只在 Settings 中显示。

## 7. 日报源仲裁

### 7.1 命令行接口

```
MailWidget --ingest <path> [--source <id>]
```

`<id>` 规则：`^[a-z0-9][a-z0-9-]{0,31}$`。不合规视为参数错误，退出码 2。

仲裁在**写入 App Group 之前**执行，读取共享 UserDefaults 的 `dailySummarySource`（默认 `"codex"`）：

| `--source` | 设置值 | 行为 | 退出码 |
|---|---|---|---|
| 未传 | 任意 | 接受并写入 | 0 |
| 传入值 == 设置值 | — | 接受并写入 | 0 |
| 传入值 != 设置值 | — | 拒收，不写入，保留上一份有效日报 | 3 |

"未传即接受"是刻意的向后兼容保险丝：即便 `automation.toml` 漏改，既有的每日运行也不会失败。

JSON schema 校验（`DailySummaryValidator`）在仲裁**之后**执行，顺序不变。校验失败仍是退出码 1
且不覆盖上一份有效日报——这条既有保护对任何新来源同样生效，因此接入新 agent 弄不坏当前日报。

### 7.2 共享状态键

存于 App Group UserDefaults（suite = `LR8V7939D4.com.kris.mailwidget`）：

| 键 | 类型 | 默认 | 用途 |
|---|---|---|---|
| `dailySummarySource` | String | `"codex"` | 当前选中的日报源 |
| `dailySummaryKnownSources` | [String] | `["codex", "claude"]` | Settings Picker 的选项，用户接入新 agent 时追加 |
| `dailySummaryLastSource` | String? | nil | 上次成功写入的来源 |
| `dailySummaryLastIngestAt` | Date? | nil | 上次成功写入时间 |
| `didMigrateGmailDailyData` | Bool | false | 迁移是否已执行（§8） |

### 7.3 Settings UI

在现有 `SettingsView` 的 Form 中新增一个 Section，位于 "Refresh" 之后：

```
Section("Gmail 日报")
  Picker  日报源    [Codex ▾]        ← dailySummaryKnownSources
  Text    上次日报：Codex、今天 09:06  ← 或"尚未收到日报"
  ---
  Button  一键添加到 Codex…
  Button  一键添加到 Claude…
  Button  为其它 CLI agent 生成定时任务…
  HStack  [复制提示词]  [导出模板…]
  Text    能读 Gmail、能跑 shell 命令的 agent 都能接；
          定时和增量游标由本 App 补齐。          ← 说明文字
```

现有 Section（Refresh / Startup / Permissions）不动。

## 8. 日报生产者契约 v1

这是本设计对外的**唯一接口**。任何 agent 满足它即可成为日报源。

### 8.1 适配前提

| 能力 | 必需原因 | 谁提供 |
|---|---|---|
| 读取 Gmail | 抓取邮件 | **agent 自身，硬门槛** |
| 执行本地 shell 命令 | 调用 `--ingest` | **agent 自身，硬门槛** |
| 被定时触发 | 每天运行 | agent 自带，或 App 用 launchd 补齐 |
| 持久化少量状态 | 增量游标 | agent 自带，或 App 分配独立游标文件补齐 |

无法读取 Gmail 的 agent 接不了。这一点在 Settings 说明文字中如实告知，不含糊。

已实测：headless `claude -p` 可以调用 claude.ai Gmail 连接器并返回结果。
但 `claude mcp list` 观察到连接器 tools fetch 偶发超时，因此 Claude 侧脚本必须带重试（§9.2）。

### 8.2 三步契约

Agent 在每次"已验证成功"或"已验证零邮件"的运行后，必须且只须完成：

1. 原子写 UTF-8 JSON 到 `<DATA_DIR>/latest.json`
   （先写同目录临时文件，完全关闭，再 rename 覆盖；不得追加或暴露半成品）
2. 执行 `<INGEST_CMD>`
3. 将增量游标写入 `<CURSOR_FILE>`

失败语义：账号不匹配、连接器失败或抓取不完整时，**不得**覆盖 `latest.json`、不得调用 `<INGEST_CMD>`、
不得推进游标。

### 8.3 占位符

App 渲染模板时把三个占位符替换为真实值：

| 占位符 | 渲染示例 |
|---|---|
| `<DATA_DIR>` | `/Users/kris/Library/Application Support/GmailDailyWidget` |
| `<INGEST_CMD>` | `/Applications/MailWidget.app/Contents/MacOS/MailWidget --ingest "<DATA_DIR>/latest.json" --source gemini` |
| `<CURSOR_FILE>` | `/Users/kris/Library/Application Support/GmailDailyWidget/cursor-gemini.md` |

`--source` 的值在渲染时就已写死在 `<INGEST_CMD>` 内，agent 不需要理解这个参数。

每个来源使用**独立游标文件**，互不干扰。Codex 是例外：它继续用自己的
`~/.codex/automations/daily-gmail-summary/memory.md`，因为该文件已有历史游标，换文件会丢失增量位置。

### 8.4 JSON schema

沿用现状，不做任何修改。根对象恰好包含 `schemaVersion`(=1)、`mailbox`、`generatedAt`(RFC 3339 带偏移)、
`headline`、`items`。`items` 至多 6 项，每项恰好包含 `id`、`level`、`title`、`detail`、`gmailURL`。
`level` ∈ {`immediate`,`today`,`week`,`optional`,`info`}。
`gmailURL` 必须形如 `https://mail.google.com/mail/u/0/?authuser=krisxia%40umich.edu#all/<id>`，
且 `<id>` 与该项 `id` 一致。

## 9. 四个调度出口

全部由 `DailySourceInstaller` 实现。每个出口都是**一次性写入**，写完不再管理。
每个出口在执行前弹出确认，展示将要写入的完整路径与内容摘要。

### 9.1 一键添加到 Codex

行为取决于是否已存在日报任务，两种情形互斥：

- **已存在 `~/.codex/automations/daily-gmail-summary/`**（当前就是这种情形）：
  **不新建、不覆盖、不删除**——它持有历史增量游标，重建会丢失增量位置。
  Settings 显示"已检测到现有 Codex 日报任务"，按钮变为"更新其 ingest 路径"，
  只做最小改写：替换 prompt 中的 `--ingest` 命令与 `osascript` 路径（§10），其余一字不动。
  改写前自动备份为 `automation.toml.bak.<时间戳>`。
- **不存在任何 Codex 日报任务**：新建 `~/.codex/automations/gmail-daily/automation.toml`，
  prompt 由模板渲染，`rrule` 沿用每天 09:00，游标使用该目录下的 `memory.md`。

### 9.2 一键添加到 Claude

写两个文件：

- `~/Library/Application Support/GmailDailyWidget/claude-daily-prompt.md` — 渲染后的完整 prompt
- `~/Library/LaunchAgents/com.kris.gmaildaily.claude.plist`

plist 要点：

- `StartCalendarInterval`：Hour 9、Minute 7。避开整点，且与 Codex 的 09:00 错开，两者不会同时写入。
- `ProgramArguments`：`/bin/bash`, `<scripts/claude_daily_summary.sh 的绝对路径>`
- launchd 的 PATH 极窄，脚本内一律使用绝对路径（`/Users/kris/.local/bin/claude`）
- `StandardOutPath` / `StandardErrorPath` 指向 `~/Library/Logs/gmail-daily-claude.log`
- 写入后执行 `launchctl bootstrap gui/$UID <plist>` 并校验 `launchctl print` 能查到该 label

`claude_daily_summary.sh` 需带重试：最多 3 次，间隔 60 秒，任一次成功即退出。
重试是为了覆盖 §8.1 观察到的连接器 tools fetch 偶发超时。

### 9.3 为其它 CLI agent 生成定时任务

用户在 App 内填三项：

- 来源 id（写入 `dailySummaryKnownSources`，并用于渲染 `--source`）
- 启动命令模板，例如 `gemini -p {PROMPT_FILE}`
- 触发时间

App 渲染 prompt 文件，生成 launchd plist（结构同 §9.2），装载并校验。
命令模板中的 `{PROMPT_FILE}` 是唯一支持的占位符。

### 9.4 复制模板 / 导出模板

- **复制提示词**：渲染后的 prompt 全文进剪贴板，占位符已展开为真实路径。
- **导出模板…**：让用户选目录，写入 `gmail-daily-template/`：

```
gmail-daily-template/
├─ prompt.md      渲染后的完整提示词，占位符已展开
├─ CONTRACT.md    §8 三步契约 + 适配前提表 + 失败语义
└─ schema.json    latest.json 的 JSON Schema，供对方 agent 自校验
```

对方 agent 如何配置定时，不在本 App 职责内。

## 10. 必须同步修改的外部文件

`~/.codex/automations/daily-gmail-summary/automation.toml` 的 prompt 中有两处硬编码路径：

```
/Applications/GmailDailyWidget.app/Contents/MacOS/GmailDailyWidget --ingest "…"
  →  /Applications/MailWidget.app/Contents/MacOS/MailWidget --ingest "…" --source codex

osascript /Users/kris/Documents/General/GmailDailyWidget/scripts/update_note.applescript
  →  osascript /Users/kris/Documents/mail_widget/scripts/update_note.applescript
```

改动前先备份该文件。改动后手工触发一次验证，不等次日 09:00。

Apple Notes 发布路径**保持启用**。它当前是活的（`memory.md` 记录 `Apple Notes publish succeeded`），
不在本次合并的删除范围内。

## 11. 迁移

### 11.1 App Group 数据

`DailySummaryMigration` 在 `applicationDidFinishLaunching` 中执行一次：

- 若 `didMigrateGmailDailyData == true`，直接返回
- 若新容器已存在 `latest.json`，标记完成并返回
- 若旧容器 `LR8V7939D4.com.kris.GmailDailyWidget/latest.json` 存在，复制到新容器，标记完成
- **旧容器文件保留，不删除**

### 11.2 用户可感知的代价

必须提前告知，均无法避免：

1. **桌面上现有的「Gmail 日报」组件会失效**，需要右键重新添加一次。
   extension 的 bundle ID 从 `com.kris.GmailDailyWidget.WidgetExtension` 变为
   `com.kris.mailwidget.widget`，系统视为新组件。
2. **MailWidget 的「完全磁盘访问」需要重新授权**。TCC 授权绑定 bundle 路径与签名，
   从 DerivedData 移到 `/Applications` 后授权不继承。未重新授权会自动降级到 AppleScript 兜底通道
   （功能可用但只读 10 封、且会拉起 Mail.app）。
3. `/Applications/GmailDailyWidget.app` **暂不删除**，等新链路验证通过后再由用户决定。

widget 的 `kind` 保持 `com.kris.GmailDailyWidget.daily` 不变——它是 extension 内部标识，
换值没有收益，只会多一处变更。

## 12. 构建与安装

移植 GmailDailyWidget 的 `scripts/install.sh`，改动点：

| 常量 | 新值 |
|---|---|
| `HOST_BUNDLE_ID` | `com.kris.mailwidget` |
| `EXTENSION_BUNDLE_ID` | `com.kris.mailwidget.widget` |
| `APP_NAME` / `SCHEME_NAME` | `MailWidget` |
| App Group | `${TEAM_ID}.com.kris.mailwidget` |

其签名校验、事务式替换、失败回滚、`pluginkit` 注册与校验逻辑全部保留。

`project.yml` 需改为用 `$(APP_GROUP_IDENTIFIER)` 变量注入 App Group（现在是硬编码
`LR8V7939D4.com.kris.mailwidget`），与 install.sh 的注入方式一致。

从 DerivedData 直接运行的旧方式不再是主路径：Codex automation 需要一个稳定的 `/Applications`
路径才能调用 `--ingest`。

## 13. 测试

| 范围 | 内容 |
|---|---|
| 搬入 | GmailDailyWidget 现有 15 个 `DailySummaryValidator` / `DailySummaryStore` 测试，全部保留 |
| 新增 | 仲裁矩阵：未传 / 匹配 / 不匹配 三种情形的退出码与"上一份日报是否被保留" |
| 新增 | `--source` id 格式校验：合规、含大写、含空格、超长、空串 |
| 新增 | 迁移：新容器已有数据时不覆盖；旧容器有数据时复制成功；两者皆无时不报错；flag 生效后不重复执行 |
| 新增 | 模板渲染：三个占位符全部替换，输出中不残留 `<DATA_DIR>` / `<INGEST_CMD>` / `<CURSOR_FILE>` |
| 手工 | 两个 widget 在 Medium / Large 下并排截图比对；日报 Medium 3 行不溢出 |

## 14. 分步实施

每步结束都可独立验证，且不需要用户重复摆放桌面组件（重摆只在第 1 步之后发生一次）。

| 步 | 内容 | 验证方式 | 风险 |
|---|---|---|---|
| 1 | 源码合并、install.sh 移植、改 automation.toml、数据迁移 | 手工触发一次 Codex 日报，确认新 app 收到并渲染 | 中：动身份与调度 |
| 2 | `WidgetTheme` 抽取、日报侧套用、`ViewThatFits` | 截图比对；确认 MailWidget 渲染逐像素未变 | 低：纯 UI |
| 3 | 仲裁、Settings UI、四个调度出口、Claude launchd 作业 | 仲裁矩阵测试；实际装一次 Claude 作业并手工触发 | 中：新功能 |

## 15. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 改 `automation.toml` 出错导致次日 09:00 静默失败 | 改前备份；改后立即手工触发验证；`--source` 缺省接受作为保险丝 |
| 字号变大导致日报 Medium 溢出 | `ViewThatFits` 阶梯（§6.2），并在第 2 步截图确认 |
| 完全磁盘访问未重新授权，MailWidget 静默降级 | 第 1 步验证清单中显式检查 Settings 的 "Active data source" 显示为 envelopeIndex |
| Claude 连接器 tools fetch 偶发超时 | 脚本 3 次重试、间隔 60 秒；日志落盘便于事后排查 |
| 两个来源同时写入 `latest.json` | 时间错开（Codex 09:00 / Claude 09:07）；写入为原子 rename；仲裁保证只有一个来源能通过 |
| 抽取 `WidgetTheme` 时意外改变 MailWidget 渲染 | token 初值逐个取自现有字面量；第 2 步截图逐像素比对 |

## 16. 待确认

无。§4 的四项决策均已确认。
