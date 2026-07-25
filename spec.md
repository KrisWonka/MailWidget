# spec.md — MacMail Widget（绑定 Mac 本机 Mail.app 的桌面小组件）

> 由 lead 根据 scout（技术调研）+ market（市场调研）两份报告汇总。日期：2026-07-22。
> 状态：**待用户审批**。批准后进入阶段二（开发）。

---

## 0. 调研结论摘要

- **没有现成可用的**：全网/GitHub 无任何「WidgetKit 原生桌面 widget + 绑定本机 Mail.app」的项目。旧式桌面挂件技术（Dashboard、Today Extension）已死；Übersicht/GeekTool 是非 WidgetKit 的 HTML 悬浮层；商业邮件客户端（Spark/Mimestream/Canary/Edison/Airmail）的 widget 全部只在 iOS 端，Mac 端最多菜单栏角标。→ **从零做**。
- **数据层最佳参考**：`che-apple-mail-mcp`（github.com/PsychQuant/che-apple-mail-mcp，MIT）验证了直接只读 Mail.app 的 `Envelope Index` SQLite（需完全磁盘访问权限），25 万封邮件毫秒级查询；AppleScript 是慢速但官方受支持的兜底。
- **市场**：真实但小众（Apple 社区同类帖 169 票 "Me too"，多社区多年反复出现）；同类小工具定价带 $6–25 买断。本项目先按**自用工具**做，商业化留作后话。

## 1. 核心功能清单（MVP，对齐苹果自带 Mail widget）

| # | 功能 | 说明 |
|---|------|------|
| F1 | 未读数 | 按所选邮箱范围显示未读计数 |
| F2 | 最近邮件列表 | 发件人、主题、正文摘要、时间；按尺寸显示 1/3/6+ 封 |
| F3 | 每个 widget 实例可配置 | 选择范围：所有收件箱 / 指定账户 / VIP / 旗标（AppIntents 配置） |
| F4 | 点击跳转 | 点卡片打开 Mail.app；点单封邮件用 `message:<message-id>` deep link 直达该邮件 |
| F5 | 全尺寸支持 | systemSmall / systemMedium / systemLarge；systemExtraLarge 按系统可用性条件启用 |
| F6 | 自动刷新 | 宿主 app 定时（默认 2 min，可调）抓取快照 + 手动立即刷新 |
| F7 | 权限引导 | 设置窗口内引导用户授予 完全磁盘访问 / 自动化 权限，并显示当前授权状态 |

**MVP 非目标**：widget 内写邮件/标记已读（可作 v2 交互式 widget）、上架 App Store、iCloud 同步配置。

## 2. 技术选型

- **语言/框架**：Swift + SwiftUI；WidgetKit（widget extension）+ AppKit/SwiftUI 宿主 app（LSUIElement 菜单栏常驻）。
- **最低系统**：macOS 14（桌面 widget 自 Sonoma 起）；开发机为更新系统，向下兼容以 14 为准。
- **关键架构约束**：WidgetKit extension 是沙盒短命进程，**不直接抓邮件数据**。由宿主 app 抓取 → 写快照到 App Group 容器 → `WidgetCenter.reloadAllTimelines()` → widget 只读快照渲染。这是规避「extension 内拿不到 Mail 数据」这一最大技术风险的标准解法。
- **数据源双通道**（协议抽象 `MailDataProvider`，运行时按授权状态选择）：
  1. **EnvelopeIndexProvider（主）**：只读查询 `~/Library/Mail/V*/MailData/Envelope Index`（SQLite）。快、Mail.app 不必运行。代价：需完全磁盘访问；schema 为苹果私有、随版本漂移 → 启动时探测 V 目录与表结构，失败即自动降级。
  2. **AppleScriptProvider（兜底）**：`tell application "Mail"` 取未读数与最近邮件。官方受支持、稳定，但慢且会拉起 Mail.app；需「自动化」权限。
- **分发**：Developer ID 直发（自用/公证），不进 MAS 沙盒（完全磁盘访问与 MAS 不兼容）。

## 3. 目录 / 文件分工表（一个文件只有一个 owner）

```
mail_widget/
├── spec.md                      # lead
├── MailWidget.xcodeproj         # lead（脚手架、entitlements、App Group、签名）
├── DataKit/                     # backend-dev 专属
│   ├── Models.swift             #   MailSnapshot / AccountSummary / MailboxSummary / MessageSummary
│   ├── SnapshotStore.swift      #   App Group 读写 + 原子落盘
│   ├── MailDataProvider.swift   #   协议 + 授权状态探测 + 降级逻辑
│   ├── EnvelopeIndexProvider.swift
│   ├── AppleScriptProvider.swift
│   └── RefreshScheduler.swift   #   定时抓取 + reloadAllTimelines
├── MailWidgetApp/               # frontend-dev 专属（宿主 app）
│   ├── App.swift                #   菜单栏入口（LSUIElement）
│   ├── SettingsView.swift       #   刷新间隔 / 登录启动 / 权限引导
│   └── OnboardingView.swift
├── MailWidgetExtension/         # frontend-dev 专属（widget）
│   ├── WidgetBundle.swift
│   ├── TimelineProvider.swift   #   只读 SnapshotStore
│   ├── ConfigIntent.swift       #   AppIntents：账户/邮箱选择
│   └── Views/                   #   Small/Medium/Large/ExtraLarge 四套视图 + 空态/过期态
└── Tests/                       # test-dev 专属（blocked by frontend+backend）
    ├── DataKitTests/            #   fixture SQLite 解析、快照编解码、降级逻辑
    └── SnapshotTests/           #   widget 视图快照测试
```

跨目录共享文件（如 xcodeproj、entitlements）**只由 lead 顺序修改**。

## 4. Interface Contract（前后端唯一对接面）

**契约 1 — 快照数据模型**（backend 产出，frontend 只读；JSON 存于 App Group `group.<team>.mailwidget/snapshot.json`）：

```swift
struct MailSnapshot: Codable {
    let generatedAt: Date            // frontend 据此渲染"数据过期"态（>10 min 视为过期）
    let providerKind: String         // "envelopeIndex" | "appleScript" — 供调试显示
    let accounts: [AccountSummary]
}
struct AccountSummary: Codable {
    let id: String; let name: String; let email: String
    let mailboxes: [MailboxSummary]
}
struct MailboxSummary: Codable {
    let id: String; let name: String
    let role: String                 // "inbox" | "vip" | "flagged" | "other"
    let unreadCount: Int
    let messages: [MessageSummary]   // 按时间倒序；Envelope 通道最多 50 封（2026-07-23 起，供 widget 翻页），AppleScript 通道 10 封
}
struct MessageSummary: Codable {
    let id: String                   // 稳定标识：优先 RFC Message-ID，缺失时用 Envelope ROWID 字符串
    let messageIdHeader: String?     // RFC Message-ID（不含尖括号），deep link 用；spike 证实可能为 NULL
    let sender: String; let senderEmail: String
    let subject: String; let snippet: String   // 摘要 ≤120 字符
    let date: Date; let isRead: Bool; let isFlagged: Bool
}
```

JSON 编解码统一用 `JSONEncoder/Decoder` 的 `.iso8601` 日期策略（fixture 亦然）。

**契约 2 — 读取 API**（backend 提供，frontend 在 TimelineProvider 中调用）：
`SnapshotStore.load() -> MailSnapshot?`（nil = 从未生成，渲染"请打开 MailWidget 完成设置"空态）。

**契约 3 — deep link**：frontend 用 `message://%3C<id>%3E` 打开单封邮件（双斜杠；2026-07-22 裁决统一，Foundation 实测两种形式都不被解析器破坏，选生态标准形式）；卡片整体 fallback `mailto:` 区域改为直接 `NSWorkspace` 打开 Mail.app（由宿主 app URL scheme 中转：`mailwidget://open`）。

**契约 4 — widget 配置**：ConfigIntent 的可选项（账户/邮箱列表）由 frontend 从最近一次 `MailSnapshot` 枚举，不另设通道。

**契约 5 — 共享设置**：UserDefaults suite = App Group ID（`LR8V7939D4.com.kris.mailwidget`）。键：`refreshIntervalMinutes`（Double，默认 2）。frontend 设置页写入，backend 的 RefreshScheduler 读取。

**契约 6 — 刷新 API**（backend 提供）：
`final class RefreshScheduler { static let shared: RefreshScheduler; func start(); func refreshNow() async -> Bool }`
（start() 在宿主 app 启动时调用；refreshNow 供菜单栏"立即刷新"，返回是否成功；成功后内部负责 `WidgetCenter.reloadAllTimelines()`。）

**契约 7 — 权限诊断 API**（backend 提供，frontend 设置页展示）：
`struct ProbeReport { let envelopeIndexAvailable: Bool; let envelopeIndexDetail: String; let activeProvider: String }`
`enum ProviderProbe { static func run() -> ProbeReport }`

**契约 8 — 打开 Mail API（2026-07-22 用户返工新增）**（backend 提供 `DataKit/MailAppOpener.swift`，仅宿主 app 调用）：
`enum MailAppOpener { @discardableResult static func openMessage(messageIdHeader: String) -> Bool; static func openMailbox(accountName: String?) }`
- deep link 统一 `message://%3C<id>%3E`（双斜杠）
- widget 头部邮箱名 = `Link` → `mailwidget://openMailbox?accountId=<id>`（all/vip/flagged 不带参数）；宿主 URL handler 解析后调 openMailbox
- 无 messageIdHeader 的邮件行也包 Link → 对应账户的 openMailbox，杜绝点击无反应
- **macOS 投递事实（2026-07-23 排障实锤）**：widget 里 Link 的 URL 一律投给所属 app 的 kAEGetURL（含 message://），宿主 handle() 对非 mailwidget scheme 用 `NSWorkspace.open(url, configuration: activates=true)` 转发；SwiftUI MenuBarExtra 会吞 `application(_:open:)`，必须 NSAppleEventManager 注册 'GURL'；LSUIElement app 需借点击时的激活令牌（NSRunningApplication.activate / OpenConfiguration.activates）Mail 才会到前台

**契约 11 — 全部已读（2026-07-23 新增）**：header 翻页键左侧 `envelope.open` Link → `mailwidget://markAllRead?scope=<scopeID>`（仅 all/account 且 unreadCount>0 时显示）；宿主路由 → `SnapshotStore.applyLocalMarkAllRead(scopeID:)`（乐观清零+reload）+ `MailAppOpener.markAllRead(accountNames:)`（AppleScript 批量 `set read status of every message ... to true`，不 activate）。卡片级 widgetURL 已移除——背景点击无操作，仅邮箱名/邮件行可点。

**契约 10 — 已读同步（2026-07-23 新增）**：`SnapshotStore.applyLocalReadMark(messageIdHeader:) -> Bool`（就地标记快照中该邮件已读、扣减相关邮箱 unreadCount、save + reloadAllTimelines）；宿主 handle() 转发 message:// 时调用（乐观清点）。RefreshScheduler 另挂 `Envelope Index-wal` 文件监听（debounce 3s，DELETE/RENAME 重挂；仅 Envelope 通道启用），Mail 内直接读信也能秒级同步。

**契约 9 — widget 翻页（2026-07-23 新增，仅 extension 内部）**：WidgetKit 无滚动，Large/XL 用 Button(intent:) 翻页。页状态存 App Group UserDefaults，key = `widgetPage.<scopeID>`（Int，默认 0，per-scope 共享）；`MailPageIntent(scopeID:targetPage:)` perform() 写状态后 `reloadTimelines(ofKind:"MailWidget")`；页大小 Large=6 / XL=12，TimelineProvider 切片并 clamp 越界页。未读行首加 accentColor 蓝点（F2 增强）。

**Spike 已证实的数据源事实（2026-07-22，macOS 27.0 / Mail V10；含 backend-dev 实测修正）**：
- `~/Library/Mail/V10/MailData/Envelope Index`；`messages(sender→addresses.ROWID, subject→subjects.ROWID, summary→summaries.ROWID, mailbox→mailboxes.ROWID, read, flagged, deleted, date_received)`；`mailboxes(url, unread_count)`（url 形如 `imap://<账户UUID>/INBOX`）；`addresses(address, comment)` comment=显示名；VIP 名单在 `MailData/VIPMailboxes.plist`（未配置 VIP 时为空 `{}`）。
- **修正 1**：`message_global_data` 的关联键是 `message_global_data.message_id == messages.message_id`（同名列，均非 ROWID；全库 11712/11712 命中实证），`message_id_header` 可能为 NULL。
- **修正 2（Gmail 大坑）**：Gmail 风格账户的消息物理落在 All Mail 对应的 mailboxes 行，INBOX 只是 `labels(message_id, mailbox_id)` 表挂的标签；只按 `messages.mailbox = INBOX.ROWID` 查会得到 0 封。正确做法：`m.mailbox = ? OR EXISTS(SELECT 1 FROM labels ...)` 的 union（EnvelopeIndexProvider 已如此实现）。
- 账户显示名：`~/Library/Accounts/Accounts4.sqlite` 仅覆盖"系统设置→互联网账户"配置的账户；Mail.app 内直接添加的账户查不到，兜底 "Account N"。

## 5. 风险与验证点（阶段二第一天先做）

| 风险 | 验证/缓解 |
|------|-----------|
| Envelope Index schema 与本机 macOS 版本不匹配 | 开发机上先跑一个 10 行 spike 脚本确认 V 目录、表名、字段；失败则 MVP 先走 AppleScript |
| 完全磁盘访问授权体验差 | 设置页一键跳转系统设置对应面板 + 实时检测授权状态 |
| systemExtraLarge 在目标系统不可用 | `#available` 条件编译，不可用则只注册三尺寸 |
| AppleScript 拉起 Mail.app 打扰用户 | 仅在 Envelope 通道不可用时使用，且文档标注该行为 |

## 6. 开发排期（阶段二并行分工）

1. lead：Xcode 脚手架 + App Group/entitlements + spike 验证 Envelope Index（半天）
2. backend-dev ∥ frontend-dev：按契约并行（frontend 先用 lead 提供的 fixture snapshot.json 假数据开发）
3. test-dev：blocked by 1+2，之后补测试
4. lead：联调（真实快照喂给 widget）、打包公证

## 7. 待用户拍板

- 产品名暂定 **MailWidget**（bundle id 用你的开发者 Team ID 前缀，联调时需要你登录的 Xcode 签名身份）
- 先做自用 Developer ID 直发版；是否商业化（$9.99–19.99 买断档）以后再议
