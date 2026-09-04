# 贡献指南

感谢你参与 Tunnelful。项目当前版本为 `0.1.6`，优先接受能够提升可靠性、安全性、可访问性和基础 Tunnel 工作流的聚焦改动。

当前 `0.1.6` 构建流程分别生成 Apple 芯片 `arm64` 与 Intel `x86_64` 单架构应用。

## 开始之前

- 确认问题尚未被现有任务覆盖。
- 对较大的行为变化，先说明使用场景、产品边界和验收方式，再开始实现。
- 安全问题不要公开披露，请按 [安全政策](SECURITY.md) 报告。
- 不要在问题、提交、测试、截图或示例中加入真实域名、邮箱、令牌、Tunnel 标识、凭据内容或用户绝对路径。
- 域名示例只使用 `example.com`，源站示例只使用 `127.0.0.1`。

## 开发环境

- Apple 芯片或 Intel Mac
- macOS 14 或更高版本
- 支持 Swift 5.10 的 Xcode
- 用于手动联调的官方 `cloudflared`

打开项目：

```bash
open app/TunnelApp.xcodeproj
```

## 设计与实现原则

- Tunnelful 只做原生控制面，不重写 QUIC、HTTP2、Tunnel、Access 或 WARP 协议。
- 优先调用稳定、公开的官方 `cloudflared` CLI；不要依赖隐藏参数或未承诺稳定的内部输出。
- CLI 能力可能随版本变化。新增参数时必须说明支持版本，并为不支持的版本提供明确反馈。
- 使用 `Process` 和参数数组，不拼接可执行的 shell 字符串。
- 任何可能包含秘密的输出在进入界面、错误或测试快照前都必须脱敏。
- 不读取、解析或复制 credentials 文件内容；只在确有需要时传递用户选择的路径。
- 写入用户配置前必须先校验、备份并使用原子替换。
- 远端变更必须可预览、可确认，并清楚区分“计划”“已提交”和“已生效”。
- 进程、Edge、源站、DNS 和公网访问状态不能合并为一个含义模糊的“正常”。
- 只管理由 Tunnelful 自身启动的子进程，不接管其他终端或系统服务中的 `cloudflared`。
- 未经需求允许，不新增第三方依赖；优先使用 Swift、SwiftUI、AppKit 和 Foundation。
- 面向用户的界面、错误和帮助文字使用清晰中文；命令名、配置键和产品专有名词可保留原文。

## 代码范围

- `app/TunnelApp/Core`：命令执行、配置、进程、日志与状态模型。
- `app/TunnelApp/UI`：macOS 原生界面。
- `app/TunnelAppTests`：不依赖真实账号与网络的单元测试。
- `website`：产品网站；应用与网站的功能承诺必须一致。

避免把生成目录、构建产物、账号配置和本机缓存加入版本库。

## 验证

提交改动前先运行最窄相关测试，再根据影响扩大范围。当前不依赖本地签名身份的标准测试命令是：

```bash
swift test --package-path app
```

也可以在 Xcode 中运行 `TunnelAppTests`；运行前请确保应用目标与测试目标使用一致的本地签名身份。

涉及真实 `cloudflared` 的改动还应手动确认：

- 未安装二进制时的提示。
- 版本检测与不支持能力的提示。
- 配置导入、校验失败、备份和保存。
- 进程启动、停止、重启、异常退出和应用退出。
- Edge 状态与源站状态互不混淆。
- 日志、错误和复制内容不暴露令牌、凭据或用户绝对路径。
- 菜单栏操作可用，主窗口关闭后仍能重新打开并正常退出。

构建或静态检查通过不等于真实账号联调、签名、公证或发布验收通过。请在变更说明中列出已运行和未运行的检查。

仓库级检查：

```bash
bash scripts/check-public-content.sh
npm ci --prefix website
npm run --prefix website lint
npm run --prefix website build:pages
```

维护者可在 macOS 上生成与验证 ad-hoc 预览包：

```bash
bash scripts/build-release.sh
bash scripts/verify-release.sh release/Tunnelful-0.1.6-arm64.dmg release/appcast.xml
bash scripts/verify-release.sh release/Tunnelful-0.1.6-x86_64.dmg release/appcast.xml
```

发布脚本分别生成用于公开分发的 Apple 芯片与 Intel ad-hoc 签名包，不会执行 Developer ID 签名或 Apple 公证。

## 变更说明

一次变更应尽量只解决一个明确问题，并包含：

- 问题与用户影响。
- 实现边界以及明确未做的内容。
- 风险点，尤其是凭据、配置写入、进程和网络行为。
- 已运行的测试及结果。
- 仍需维护者或真实环境完成的验证。
- 如影响用户可见行为，在 [更新日志](CHANGELOG.md) 的“尚未发布”部分增加一条简洁记录。

## 许可

提交贡献即表示你有权提供相关内容，并同意该贡献按仓库的 Apache License 2.0 许可发布。第三方代码、图标或素材必须说明来源、版本与许可证，并同步更新 [第三方声明](THIRD_PARTY_NOTICES.md)。
