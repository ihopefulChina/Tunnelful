# Tunnelful 0.1.11 设计校验

完整证据与迭代记录见仓库根目录的 `design-qa.md`。

- 官网视觉参考：`../website/public/tunnelful-window-dark-v0.1.9.png`
- 0.1.11 沿用的官网 macOS 26 外观基准：`../website/public/tunnelful-window-v0.1.10.png` / `../website/public/tunnelful-window-dark-v0.1.10.png`
- 用户原始输入与并排对照另保存在本地忽略目录 `../design/references/`，不会随仓库提交分发
- 深色实际窗口：`../design/actual-app-dark.png`
- 浅色实际窗口：`../design/actual-app.png`
- 视口：1120 × 780 pt，2240 × 1560 px @2x
- 原生侧栏分组：状态（概览、Tunnel）、配置（发布服务、Ingress 配置）、诊断（环境检查、日志）
- 系统入口：关于、设置、更新与帮助位于 macOS 屏幕顶部菜单
- 可公开内容：示例数据，无真实域名、凭据或用户绝对路径
- 发布边界：0.1.11 不改界面源码；正式 DMG 必须由 Xcode 26 / macOS 26 SDK 构建，并在 macOS 26 上从安装包复核侧栏
- 系统差异：macOS 14 与 macOS 15 采用对应系统的原生控件样式，不要求逐像素等同于 macOS 26 基准

Visual source result: passed; release package parity requires final DMG verification
