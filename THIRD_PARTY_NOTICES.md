# 第三方声明

本文说明 Tunnelful 仓库中直接使用或互操作的第三方软件。各组件仍受其各自许可证与商标条款约束。

## cloudflared

Tunnelful 与 Cloudflare 提供的官方 `cloudflared` 命令行程序互操作。

- 许可：Apache License 2.0
- 分发方式：当前 Tunnelful 发布包不包含 `cloudflared`；用户必须自行安装和更新。
- 边界：Tunnelful 不复制或重写其 QUIC、HTTP2、Tunnel、Access 或 WARP 实现。

如未来版本开始捆绑 `cloudflared`，发布流程必须同时提供对应版本、许可证文本、版权声明、来源和完整性校验信息。

## Sparkle

Tunnelful 使用 [Sparkle](https://github.com/sparkle-project/Sparkle) 在应用内检查并安装更新。

- 许可：MIT License
- 版本：2.9.2
- 更新源：`https://ihopefulchina.github.io/Tunnelful/appcast.xml`
- 边界：Sparkle 只用于应用自身更新，不参与 Cloudflare Tunnel 或 `cloudflared` 的安装。

## macOS 应用

macOS 应用使用 Swift、SwiftUI、AppKit、Foundation、Combine 与 Uniform Type Identifiers 等 Apple 平台 SDK。

Apple、macOS、Swift、SwiftUI、AppKit 及相关名称和标识归其各自权利人所有。

## 产品网站直接运行依赖

以下版本来自当前 `website/package-lock.json`：

| 软件包 | 版本 | 许可证 |
| --- | --- | --- |
| React | 19.2.8 | MIT |
| React DOM | 19.2.8 | MIT |
| React Server DOM Webpack | 19.2.8 | MIT |
| Vinext | 1.0.0-beta.9 | MIT |

网站的开发依赖与完整传递依赖清单以 `website/package-lock.json` 为准。更新依赖时，贡献者应重新核对版本、许可证和发布产物中的许可义务。

## 项目许可与商标

Tunnelful 自身按 Apache License 2.0 发布，详见仓库根目录的 `LICENSE`。

Tunnelful 是独立开源项目，与 Cloudflare, Inc. 不存在隶属、合作、赞助或背书关系。Cloudflare、Cloudflare Tunnel 与 `cloudflared` 等名称和标识归其各自权利人所有。
