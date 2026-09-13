# MailWidget

绑定 **Mac 本机 Mail.app** 的桌面小组件（WidgetKit），功能对齐苹果 iPhone 版 Mail widget：未读数、最近邮件列表、按账户/VIP/旗标筛选、点击直达单封邮件。支持 Small / Medium / Large / ExtraLarge 四种尺寸。

- 数据源：只读 Mail.app 的 `Envelope Index` SQLite（需完全磁盘访问），AppleScript 兜底
- 架构：菜单栏宿主 app 定时抓快照 → App Group → widget 渲染（widget 沙盒内不碰邮件数据）
- 详细设计见 `spec.md`

桌面上是**两个各自独立的小组件**：

- **MailWidget**（Small / Medium / Large / XL）— 实时收件箱
- **Gmail 日报**（Medium / Large）— 外部 agent 每天推送的决策简报，见 `docs/superpowers/specs/`

## 分享给别人

这份源码是**去个人化**的：Team ID、App Group、邮箱地址、AI 命令行路径全部在构建时或
运行时确定，没有任何一处写死某个人的身份。别人克隆下来跑一条命令就能用自己的 Apple
签名身份装出属于他自己的版本。

给朋友的说明见 **[SETUP.md](SETUP.md)**，他只需要跑：

```bash
~/Documents/mail_widget/scripts/setup.sh
```

前提是他机器上有完整版 Xcode 和一张免费的 Apple Development 证书（SETUP.md 里有步骤）。
脚本会自动补齐 Homebrew / xcodegen / claude 或 codex 命令行，探测他的签名身份，
构建安装，并把邮箱与引擎配置写好。

## 安装 / 更新

**在 Mac 终端跑**：

```bash
~/Documents/mail_widget/scripts/install.sh
```

它会构建 Release、逐项校验签名（Team ID、bundle ID、App Group、拒绝 ad-hoc 与
provisioning profile），然后**事务式**替换 `/Applications/MailWidget.app`：新版通过全部
校验并完成 pluginkit 注册前，旧版一直保留；中途出错或被中断会自动回滚并重新注册旧
extension。

必须装到 `/Applications` 而不是从 DerivedData 直接跑——日报的定时任务需要一个稳定的绝对
路径来调用 `--ingest`。

首次启动后：

1. 菜单栏出现信封图标（app 无 Dock 图标，LSUIElement）
2. 给 **MailWidget.app** 授予「完全磁盘访问」：系统设置 → 隐私与安全性 → 完全磁盘访问（设置页有一键跳转按钮）。不授予则自动降级 AppleScript 模式（会请求"自动化"权限并拉起 Mail.app）
3. 桌面右键 → 编辑小组件 → 搜 "MailWidget" → 添加想要的尺寸
4. widget 右键 → 编辑，可切换显示范围（所有收件箱 / 单账户 / VIP / 旗标）

## 测试

**在 Mac 终端跑**：

```bash
cd ~/Documents/mail_widget
xcodebuild test -project MailWidget.xcodeproj -scheme MailWidget -only-testing:DataKitTests
```

**不要给测试加 `-derivedDataPath .build/DerivedData`。** 本仓库位于 `~/Documents` 之下，
而该目录受 TCC 保护；xcodebuild 拉起的 `xctest` 进程拿不到「文稿文件夹」权限，会看不见测试
bundle 而报错 `Failed to create a bundle instance`——bundle 其实是好的，`xcrun xctest` 直接跑
就能过。用默认的 DerivedData 路径即可。（`install.sh` 只做 `clean build` 不跑测试，所以它用
仓库内的 `.build/DerivedData` 没有这个问题。）

## 目录结构 / 分工

见 `spec.md` §3。`DataKit/` 数据层，`MailWidgetApp/` 菜单栏宿主，`MailWidgetExtension/` widget，`Tests/` 单元测试。
