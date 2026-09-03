# 发布流程

本文供 Tunnelful 维护者使用。所有发布均应从干净的 `main` 分支生成。`0.1.4` 分别提供 Apple 芯片 `arm64` 与 Intel `x86_64` 单架构安装包，两者均采用 ad-hoc 签名且未公证。更新源由 Sparkle appcast 提供。

## 发布门槛

发布前应同时确认：

- 根目录 `VERSION`、`CHANGELOG.md` 与对应发布说明中的完整版本一致。
- `app/Config/Product.xcconfig` 的 `MARKETING_VERSION` 使用三段数字，`TUNNELFUL_RELEASE_VERSION` 与根目录完整版本一致。`CURRENT_PROJECT_VERSION` 必须是大于等于 5 的奇数：Apple 芯片使用该值，Intel 使用前一个偶数。
- 应用与网站没有真实域名、个人绝对路径、账号标识、凭据或令牌。
- `swift test --package-path app` 通过。
- Release 配置的 `arm64` 与 `x86_64` Xcode 构建分别通过，并确认每个主程序只包含对应架构。
- `npm ci --prefix website`、网站静态检查和 GitHub Pages 构建通过。
- 发布磁盘映像的签名、架构、Bundle ID、菜单栏模式、内容与 SHA-256 校验通过。
- 分别在 Apple 芯片与 Intel Mac 上完成首次打开、拖入“应用程序”、菜单栏常驻、主窗口关闭与退出检查。

真实 Cloudflare 账号、Tunnel、DNS 和公网访问验证属于单独的 UAT 门槛。自动化构建通过不能替代这项验证。

## 本地候选包

在仓库根目录执行：

```bash
bash scripts/check-public-content.sh
swift test --package-path app
npm ci --prefix website
npm run --prefix website lint
npm run --prefix website build:pages
bash scripts/build-release.sh
bash scripts/verify-release.sh release/Tunnelful-0.1.4-arm64.dmg release/appcast.xml
bash scripts/verify-release.sh release/Tunnelful-0.1.4-x86_64.dmg release/appcast.xml
```

`build-release.sh` 会从根目录 `VERSION` 读取完整发布版本，校验应用中的三段数字版本与 `TUNNELFUL_RELEASE_VERSION`，并把完整版本写入应用 Info.plist。随后分别构建仅含 `arm64` 与仅含 `x86_64` 的 Release 应用，削薄 Sparkle 等嵌入二进制，应用 ad-hoc 签名，生成两个 DMG、SHA-256 文件以及 Sparkle `appcast.xml`。生成更新源需要 `TUNNELFUL_SPARKLE_ED_PRIVATE_KEY`。脚本不会访问开发者证书，不会上传产物，也不会执行 Apple 公证。

## GitHub Release

推送与产品版本一致的标签后，`.github/workflows/publish-app.yml` 会重新测试、构建并验证候选包，然后创建 GitHub Release。只有版本号包含预发布段时才会标记为预发布。当前版本对应标签为：

```text
v0.1.4
```

不要在自动发布运行成功前手工创建同名 Release，否则工作流会因名称冲突失败。发布完成后再次下载公开附件，核对 SHA-256，并确认 Release 页面醒目标明以下事实：

- 同时提供 Apple 芯片 `arm64` 与 Intel `x86_64` 安装包，最低系统版本为 macOS 14。
- 发布包只有 ad-hoc 签名。
- 发布包未经过 Apple 公证。
- 用户必须自行安装官方 `cloudflared`。
- Sparkle 更新源应同时出现在 GitHub Release 与 GitHub Pages 的 `/Tunnelful/appcast.xml`。

## GitHub Pages

仓库应在 Pages 设置中选择“GitHub Actions”作为发布源。推送 `main` 的网站改动后，`.github/workflows/pages.yml` 会运行静态检查、构建 `website/dist/client` 并部署。

首次发布后需要验证首页与静态资源均能从仓库子路径访问，页面中的下载入口应指向当前 GitHub Release，不应链接本机文件或未公开附件。

## 正式签名留档

当项目取得 Apple Developer ID 后，应另行实现钥匙串导入、Developer ID 签名、公证提交、票据装订与 Gatekeeper 验证。完成这些步骤前，任何发布包都不得宣称“已使用 Developer ID 签名”“已公证”或“可绕过安全提示安装”。
