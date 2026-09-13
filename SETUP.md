# 装这个东西（给第一次拿到源码的人）

MailWidget 是一个 macOS 桌面小组件，把你 Mail.app 里的邮件放到桌面上，并且可以让
Claude 或 Codex 每天早上替你把邮件读一遍、写成中文简报。

装完你会得到三样东西：

| | 作用 | 需要什么 |
|---|---|---|
| **收件箱小组件** | 桌面上显示未读数和最近邮件，点一封直接在 Mail 里打开 | 只要用 Mail.app |
| **邮件总结** | 点一下，AI 把收件箱最近 20 封写成中文摘要 | 要装 Claude 或 Codex 命令行 |
| **Gmail 日报** | 每天早上自动生成一份「今天有什么要处理」的简报 | 要 Gmail + Claude 或 Codex |

---

## 一条命令

**在你 Mac 的终端里跑**（把路径换成你放这份源码的位置）：

```bash
~/Documents/mail_widget/scripts/setup.sh
```

脚本会依次做：检查依赖（缺的能自动装的就装）→ 用**你自己的** Apple 签名身份构建 →
装进 `/Applications` → 写入你的邮箱和 AI 引擎配置 → 打开该授权的系统设置面板。

跑到一半失败了不要紧，**修好提示里说的问题再跑一次就行**，已完成的步骤会自动跳过。

---

## 你需要先准备的两样（脚本装不了，得你点几下）

### 1. Xcode（约 10 GB）

构建桌面小组件必须要完整版 Xcode，命令行工具不够。到 App Store 搜 Xcode 装，
装完**打开一次**同意许可协议。

⚠️ **如果你机器上已经有 Xcode 但打不开**（双击没反应，或终端里 `open -a Xcode` 报
`-10664`）：那是 macOS 主动禁用了过旧的 Xcode——新系统会硬性要求配套版本的 Xcode
（例如 macOS 27 要 Xcode 27+）。

先去 App Store 的「更新」看有没有新版 Xcode——有就直接升，免费。**如果商店里没有更新、
只显示「打开」**，说明配套的 Xcode 还没正式发布（只到 beta/RC，而这两种不上架 App Store）。
这时要么去 <https://developer.apple.com/download/applications/> 用免费 Apple ID 登录后下载
对应版本，要么等它上架。

注意这种情况下命令行 `xcodebuild` 往往还能正常工作（它不走这套兼容性检查），所以别被
"构建没问题"误导成 Xcode 没问题——本项目的构建脚本用的就是命令行，图形界面打不开
并不影响安装。

### 2. 一张免费的 Apple 开发者证书

不需要花钱，普通 Apple ID 就行：

1. 打开 Xcode → 菜单栏 **Xcode → Settings → Accounts**
2. 左下角 **+** → 登录你的 Apple ID
3. 选中账号 → **Manage Certificates…** → 左下角 **+** → **Apple Development**

这张证书是用来给 app 签名的。**你签出来的 app 只在你自己电脑上跑**，跟原作者的签名无关，
所以 App Group、数据目录这些都会自动换成你自己的，不会互相干扰。

---

## 关于「登录」：这个 app 没有登录框，也不碰你的邮箱密码

安装时会问你一个 Gmail 地址，**那不是登录**——它只是告诉程序「日报要总结哪个邮箱」，
顺便用来校验收到的日报确实属于这个邮箱、以及拼 Gmail 网页链接。真正的读取权限来自
两个它管不着的地方：

| 功能 | 读什么 | 凭证在谁那里 |
|---|---|---|
| 收件箱小组件 | 你本机 Mail.app 的数据库 | Mail.app 里你早就登录好的账户（给「完全磁盘访问」就能读） |
| 邮件总结 | 本机 Mail.app 取正文，交给 AI 写摘要 | 同上 + 你的 claude / codex 命令行自己的账号 |
| **Gmail 日报** | **Gmail 服务器**（不走本机 Mail） | **你 Claude（或 Codex）账号里的 Gmail 连接器** |

所以**想用 Gmail 日报，还得多做一步**：在 Claude 里把 Gmail 连上。

**Claude**：打开 [claude.ai](https://claude.ai) → Settings → Connectors → Gmail → 连接，
用你要总结的那个 Gmail 账号授权。连完在终端里跑 `claude mcp list`，看到
`claude.ai Gmail: ... ✔ Connected` 就成了。

**Codex**：在 Codex 的 connectors / MCP 设置里连 Gmail，`codex mcp list` 能看到即可。

`setup.sh` 会自动帮你检测这一步，没连上会明确提示（收件箱小组件和邮件总结不受影响，
只有日报会失败）。连好之后不用重跑脚本，日报下次运行自动生效。

## 装完之后（三件手动的事）

1. **给完全磁盘访问**：脚本会自动打开「系统设置 → 隐私与安全性 → 完全磁盘访问」，
   把列表里的 **MailWidget** 打开。
   *不给也能用*，但会退化成慢得多的 AppleScript 模式，而且会不停把 Mail 唤到前台。

2. **把小组件放到桌面**：桌面空白处**右键 → 编辑小组件**，搜 `MailWidget`，
   把「MailWidget」（收件箱）或「Gmail 日报」拖到桌面。小组件右键 → 编辑，
   可以切换显示哪个账户。

3. **（可选）让日报每天自动跑**：点菜单栏的信封图标 → **设置** → Gmail 日报 →
   一键添加到 Claude / Codex。它会装一个 macOS 定时任务（launchd），每天早上自动生成。

---

## 常见问题

**Q：日报和总结要花钱吗？**
走的是你自己机器上的 `claude` 或 `codex` 命令行，用的是你自己的账号额度，
这个 app 本身不联网、不经过任何第三方服务器。

**Q：我的邮件会被发到哪里去？**
收件箱小组件完全本地。邮件总结和日报会把邮件内容交给你选的那个 AI 命令行
（即发往 Anthropic 或 OpenAI）——这一步和你平时在终端里用它们是一回事。

**Q：菜单栏数据源显示 appleScript，是不是坏了？**
不是坏，是没给完全磁盘访问。给了之后会自动切回快得多的本地数据库模式。

**Q：桌面小组件改了代码不更新？**
macOS 会缓存小组件进程。重新跑一次 `scripts/setup.sh` 即可，它每次都会换一个新版本号
逼系统丢掉缓存。

**Q：可以不用 Gmail 吗？**
收件箱小组件和邮件总结：任何 Mail.app 里的账户都行。
Gmail 日报：目前只支持 Gmail（它靠 AI 命令行读 Gmail）。

---

## 出问题时看哪里

| 日志 | 内容 |
|---|---|
| `~/Library/Logs/gmail-daily-claude.log` | 日报定时任务每次运行的完整输出 |
| `~/Library/Logs/mailwidget-daily-regen.log` | 手动点「重新生成」时的输出 |
| `~/Library/Logs/mailwidget-mail-summary.log` | 邮件总结的输出 |

设置里也能看到「上次日报 / 上次总结」的时间和当时用的引擎。
