# Tunnelful 0.1.11 设计校验

## 验收输入

- 官网参考图（仓库内可复核）：`website/public/tunnelful-window-dark-v0.1.9.png`
- 用户提供的原始输入（与上图 SHA-256 完全相同；本地副本不随提交分发）：`design/references/official-overview-dark-v0.1.9.png`
- 当前深色实现：`design/actual-app-dark.png`
- 当前浅色实现：`design/actual-app.png`
- 0.1.11 沿用的官网深色外观基准：`website/public/tunnelful-window-dark-v0.1.10.png`
- 0.1.11 沿用的官网浅色外观基准：`website/public/tunnelful-window-v0.1.10.png`
- 完整并排对比（仅本地）：`design/references/qa-full-dark-v0.1.9.png`
- 侧栏聚焦对比（仅本地）：`design/references/qa-sidebar-dark-v0.1.9.png`
- 视口：1120 × 780 pt，2240 × 1560 px @2x，标准 sRGB
- 截图状态：主窗口已激活、深色外观、概览页、`dev` 运行中、Cloudflare Edge 已连接、源站尚未检查

## 目标与允许差异

当前实现复用原生 SwiftUI `NavigationSplitView`、`List`、`Section` 和系统工具栏，保持官网截图的窗口比例、侧栏宽度、标题层级、卡片边界、留白、系统图标与低饱和深色材质。唯一的结构性差异是按用户要求在左侧增加三组：

- 状态：概览、Tunnel
- 配置：发布服务、Ingress 配置
- 诊断：环境检查、日志

对比图中的 PID、cloudflared 版本、连接文案和示例路径属于安全测试夹具产生的运行内容差异，不是视觉偏差。公开截图不包含真实域名、凭据、账户名或用户绝对路径；主目录使用 `$HOME` 显示，交互仍保留原始完整路径。

## 迭代记录

1. 旧版截图采用无分组侧栏，且已不能证明当前实现，故不作为最终验收证据。
2. 第一轮分组实现使用真实原生窗口验证时，发现首启窗口可能未进入激活态、截图出现启动提示且测试夹具路径暴露 `/tmp`；随后修复首启应用激活，改用手动启动的稳定验收状态，并为主目录路径增加 `$HOME` 安全显示。
3. 最终重新采集深色与浅色窗口，并在相同 1120 × 780 pt 视口下完成完整页面和侧栏局部并排对比。未发现 P0、P1 或 P2 级可见偏差；交通灯、选中态、分组间距、内容对齐、按钮、边框和圆角均完整，无裁切或溢出。

## 0.1.11 发布包一致性

- 0.1.10 官网截图来自 Xcode 26 / macOS 26 SDK 构建的当前界面源码，但 0.1.10 正式 DMG 使用旧 SDK 构建，导致同一原生 `NavigationSplitView` 在 macOS 26 上仍呈现旧式侧栏。
- 0.1.11 不修改界面源码，也不重新生成截图；正式包改用 Xcode 26 与 macOS 26 SDK 后，现有两张截图继续作为 macOS 26 外观基准。
- 最终验收必须从 0.1.11 的公开 DMG 启动应用并核对构建 SDK 与侧栏，不得用本地 Debug App、源码截图或网站图片代替安装包验收。
- macOS 14 与 macOS 15 会按各自系统版本呈现原生控件，外观不要求逐像素等同于 macOS 26 截图，但必须保持功能、布局可用且无裁切。

## 结论与边界

- README 与官网继续使用已验收的浅色、深色 macOS 26 外观基准；官网图片与对应 `design/actual-app*.png` 逐字节一致，0.1.11 未改动界面源码。
- 干净克隆可复核官网基准、两张当前实现截图与本记录；两张并排合成图是本次本地 QA 证据，不宣称随公共仓库提供。
- 系统浅色/深色、自适应窗口、键盘侧栏选择与 VoiceOver 语义由原生控件承载。
- 本次视觉验收未操作真实 Cloudflare 账户、DNS 或公网源站；这些仍属于真实环境 UAT，而不是截图验收的一部分。

Visual source result: passed; release package parity requires final DMG verification
