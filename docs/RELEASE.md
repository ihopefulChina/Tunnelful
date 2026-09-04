# 发布流程

本文供 Tunnelful 维护者使用。所有发布均应从干净的 `main` 分支生成。`0.1.11` 分别提供 Apple 芯片 `arm64` 与 Intel `x86_64` 单架构安装包，两者均采用 ad-hoc 签名且未公证。更新源由 Sparkle appcast 提供。

## 发布门槛

发布前应同时确认：

- 根目录 `VERSION`、`CHANGELOG.md` 与对应发布说明中的完整版本一致。
- `app/Config/Product.xcconfig` 的 `MARKETING_VERSION` 使用三段数字，`TUNNELFUL_RELEASE_VERSION` 与根目录完整版本一致。`CURRENT_PROJECT_VERSION` 必须是大于等于 5 的奇数：Apple 芯片使用该值，Intel 使用前一个偶数。
- 正式发布必须显式选择 Xcode 26，并由构建与安装包验证确认使用 macOS 26 SDK；`MACOSX_DEPLOYMENT_TARGET` 继续保持 14.0。不能仅凭 runner 名称推断实际 Xcode/SDK 版本。
- 应用与网站没有真实域名、个人绝对路径、账号标识、凭据或令牌。
- `swift test --package-path app` 通过。
- Release 配置的 `arm64` 与 `x86_64` Xcode 构建分别通过，并确认每个主程序只包含对应架构。
- `npm ci --prefix website`、网站静态检查和 GitHub Pages 构建通过。
- 发布磁盘映像的签名、架构、Bundle ID（必须为 `app.ihopeful.Tunnelful`）、菜单栏模式、内容与 SHA-256 校验通过。
- 分别在 Apple 芯片与 Intel Mac 上完成首次打开、拖入“应用程序”、菜单栏常驻、主窗口关闭与退出检查。

真实 Cloudflare 账号、Tunnel、DNS 和公网访问验证属于单独的 UAT 门槛。自动化构建通过不能替代这项验证。

## 0.1.10 Bundle ID 迁移

0.1.9 及更早版本使用 `app.tunnelful.mac`，0.1.10 起使用 `app.ihopeful.Tunnelful`。Sparkle 将 Bundle ID 视为更新身份的一部分，因此旧版不能通过普通 DMG 更新直接替换为 0.1.10。发布说明、README 与官网必须同时提示用户手动下载对应架构的 DMG、退出旧版并替换“应用程序”中的旧应用。

两个身份继续共用 `/Tunnelful/appcast.xml`，因此 0.1.10 及后续版本的每个架构条目都必须包含 `sparkle:informationalUpdate`，并以 `sparkle:belowVersion` 设为 `26`。这样旧版 Intel build 24 与 Apple 芯片 build 25 只显示迁移说明和 Release 网页入口，不会下载或安装 Bundle ID 不同的应用；0.1.10 Intel build 26、Apple 芯片 build 27 以及后续版本仍使用正常 Sparkle 更新。不得删除这条版本门槛，除非已经设计并验证新的迁移路径。

偏好设置应由 0.1.10 首次启动时自动迁移。发布验收需从安装过 0.1.9 的独立用户环境验证外观、可执行文件路径、启动 Tunnel 设置均得到保留。旧 Bundle ID 注册的 `SMAppService.mainApp` 无法由新身份可靠注销，因此升级文案必须要求已启用登录项的用户先在旧版关闭它，安装后再于 0.1.10 中重新开启；不得宣称登录项可无感迁移。

## 本地候选包

在仓库根目录执行：

```bash
bash scripts/check-public-content.sh
swift test --package-path app
npm ci --prefix website
npm run --prefix website lint
npm run --prefix website build:pages
bash scripts/build-release.sh
bash scripts/verify-release.sh release/Tunnelful-0.1.11-arm64.dmg release/appcast.xml
bash scripts/verify-release.sh release/Tunnelful-0.1.11-x86_64.dmg release/appcast.xml
```

`build-release.sh` 会先拒绝 Xcode 26 / macOS 26 SDK 之外的发布工具链，再从根目录 `VERSION` 读取完整发布版本，校验应用中的三段数字版本与 `TUNNELFUL_RELEASE_VERSION`，并把完整版本写入应用 Info.plist。随后分别构建仅含 `arm64` 与仅含 `x86_64` 的 Release 应用，削薄 Sparkle 等嵌入二进制，应用 ad-hoc 签名，生成两个 DMG、SHA-256 文件以及 Sparkle `appcast.xml`。生成更新源需要 `TUNNELFUL_SPARKLE_ED_PRIVATE_KEY`。GitHub 发版工作流必须传入该密钥；缺少密钥时不得发布。脚本不会访问开发者证书，不会上传产物，也不会执行 Apple 公证。

## GitHub Release

推送与产品版本一致的标签后，`.github/workflows/publish-app.yml` 会重新测试、构建并验证候选包，然后创建 GitHub Release。只有版本号包含预发布段时才会标记为预发布。当前版本对应标签为：

```text
v0.1.11
```

不要在自动发布运行成功前手工创建同名 Release，否则工作流会因名称冲突失败。发布完成后再次下载公开附件，核对 SHA-256，并确认 Release 页面醒目标明以下事实：

- 同时提供 Apple 芯片 `arm64` 与 Intel `x86_64` 安装包，最低系统版本为 macOS 14。
- 发布包只有 ad-hoc 签名。
- 发布包未经过 Apple 公证。
- 用户必须自行安装官方 `cloudflared`。
- Sparkle 更新源必须作为 `appcast.xml` 出现在 GitHub Release 中，并由 GitHub Pages 的 `/Tunnelful/appcast.xml` 提供给应用。

## GitHub Pages

仓库应在 Pages 设置中选择“GitHub Actions”作为发布源。推送 `main` 的网站改动后，`.github/workflows/pages.yml` 会运行静态检查、构建 `website/dist/client` 并部署。应用发布工作流成功后也会再部署一次，并把最新 GitHub Release 中的 `appcast.xml` 覆盖到官网更新源。

首次发布后需要验证首页与静态资源均能从仓库子路径访问，页面中的下载入口应指向当前 GitHub Release，不应链接本机文件或未公开附件。打开 `https://ihopefulchina.github.io/Tunnelful/appcast.xml`，确认其中的 `sparkle:shortVersionString` 与当前 `VERSION` 一致。

0.1.11 发布后逐项验证：

- `https://github.com/ihopefulChina/Tunnelful/releases/latest` 跳转到 `v0.1.11`，且 `https://github.com/ihopefulChina/Tunnelful/releases/tag/v0.1.11` 可访问。
- `Tunnelful-0.1.11-arm64.dmg`、`Tunnelful-0.1.11-x86_64.dmg`、两份 `.sha256` 与 `appcast.xml` 五个 Release 附件均可下载。
- 两个 DMG 的公开下载字节数和 SHA-256 与 Release 附件一致，应用内 `CFBundleIdentifier` 均为 `app.ihopeful.Tunnelful`。
- 两个 DMG 均由 Xcode 26 与 macOS 26 SDK 构建，最低部署目标为 macOS 14；不得只验证本地 Debug App 或工作流日志中的 runner 名称。
- 在 macOS 26 上从最终 DMG 启动，确认分组侧栏呈现与官网现有 `tunnelful-window-v0.1.10.png` / `tunnelful-window-dark-v0.1.10.png` 基准一致的原生圆角悬浮样式；macOS 14 与 macOS 15 应保持可启动并采用各自系统样式。
- `https://ihopefulchina.github.io/Tunnelful/` 展示 0.1.11 文案和上述分组侧栏基准，浅色与深色主题均使用对应图片，两个架构按钮指向 0.1.11 附件。
- `https://ihopefulchina.github.io/Tunnelful/tunnelful-window-v0.1.10.png` 与 `https://ihopefulchina.github.io/Tunnelful/tunnelful-window-dark-v0.1.10.png` 返回成功，桌面和移动端均无横向溢出。
- 更新源的两个架构条目均为 0.1.11，Intel 内部版本为 28、Apple 芯片内部版本为 29；下载 URL、文件长度、EdDSA 签名和公开附件一致，两个条目都包含 `informationalUpdate` 与 `belowVersion=26`。
- 在 0.1.9 Intel build 24 与 Apple 芯片 build 25 上分别检查更新：只能看到迁移说明和 Release 网页入口，不得下载或尝试安装 0.1.11；在 0.1.10 build 26/27 上应能正常发现并安装 0.1.11，在 0.1.11 build 28/29 上不得把当前版本误报为新版本。

## 正式签名留档

当项目取得 Apple Developer ID 后，应另行实现钥匙串导入、Developer ID 签名、公证提交、票据装订与 Gatekeeper 验证。完成这些步骤前，任何发布包都不得宣称“已使用 Developer ID 签名”“已公证”或“可绕过安全提示安装”。
