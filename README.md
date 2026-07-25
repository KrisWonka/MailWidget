# MailWidget

绑定 **Mac 本机 Mail.app** 的桌面小组件（WidgetKit），功能对齐苹果 iPhone 版 Mail widget：未读数、最近邮件列表、按账户/VIP/旗标筛选、点击直达单封邮件。支持 Small / Medium / Large / ExtraLarge 四种尺寸。

- 数据源：只读 Mail.app 的 `Envelope Index` SQLite（需完全磁盘访问），AppleScript 兜底
- 架构：菜单栏宿主 app 定时抓快照 → App Group → widget 渲染（widget 沙盒内不碰邮件数据）
- 详细设计见 `spec.md`

## 构建 & 运行

**在 Mac 终端跑**（项目根目录）：

```bash
cd ~/Documents/mail_widget
xcodegen generate
xcodebuild -project MailWidget.xcodeproj -scheme MailWidget -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/MailWidget-*/Build/Products/Debug/MailWidget.app
```

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

## 目录结构 / 分工

见 `spec.md` §3。`DataKit/` 数据层，`MailWidgetApp/` 菜单栏宿主，`MailWidgetExtension/` widget，`Tests/` 单元测试。
