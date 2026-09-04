import Image from 'next/image';

import DownloadChooser from './DownloadChooser';
import ThemeToggle from './ThemeToggle';

const repositoryURL = 'https://github.com/ihopefulChina/Tunnelful';
const releasesURL = `${repositoryURL}/releases/tag/v0.1.10`;

const basePath = process.env.TUNNELFUL_PAGES === '1' ? '/Tunnelful' : '';

function Brand() {
  return (
    <span className="brand">
      <Image
        src={`${basePath}/tunnelful-icon.png`}
        width={28}
        height={28}
        alt=""
        aria-hidden="true"
        unoptimized
      />
      <span>Tunnelful</span>
    </span>
  );
}

const features = [
  {
    label: '环境',
    title: '从安装到登录，按顺序准备好。',
    description:
      '检查 cloudflared、Homebrew、本地配置与账户状态，并引导完成官方登录。',
  },
  {
    label: '配置',
    title: '先校验，再安全保存。',
    description:
      '保留未知字段、注释和高级规则；通过本地与官方 CLI 校验后备份并原子写入，外部改动不会被静默覆盖。',
  },
  {
    label: '发布',
    title: '本地配置与远端 DNS，边界分明。',
    description:
      '源站检查只对应当前地址，Tunnel 与专属凭据必须匹配；DNS 命令先预览再确认，并明确禁止覆盖同名记录。',
  },
  {
    label: '状态',
    title: '进程、Edge 与源站各自可见。',
    description:
      '本地进程、Cloudflare Edge 与源站分开显示。Edge 按仍注册的连接判断，单条重连不等于隧道断开。',
  },
  {
    label: '常驻',
    title: '关掉窗口，隧道继续运行。',
    description:
      '窗口打开时使用完整 macOS 系统菜单；关闭后隐藏 Dock 图标并留在菜单栏。还可选择登录 Mac 时打开，并在应用启动后运行当前 Tunnel。',
  },
  {
    label: '更新',
    title: '后续更新，在应用内确认。',
    description:
      '0.1.10 起使用新的正式 Bundle ID，可继续检查后续兼容更新；旧版检查更新只显示迁移说明并引导前往 Release 页面。',
  },
];

export default function Home() {
  return (
    <main id="top">
      <header className="site-header">
        <nav className="site-nav" aria-label="主导航">
          <a className="brand-link" href="#top" aria-label="Tunnelful 首页">
            <Brand />
          </a>
          <div className="nav-links">
            <a href="#features">功能</a>
            <a href={repositoryURL}>GitHub</a>
            <ThemeToggle />
            <a className="nav-download" href="#downloads">下载</a>
          </div>
        </nav>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <p className="eyebrow">macOS 菜单栏工具</p>
        <h1 id="hero-title">
          <span>把 Cloudflare Tunnel，</span>
          <span>交给一个真正的 Mac 应用。</span>
        </h1>
        <p className="hero-description">
          检查环境，安全编辑 Ingress，预览并确认 DNS 路由，分别查看进程、Edge 与源站状态。
          窗口关闭后仍常驻菜单栏。
        </p>
        <DownloadChooser />
        <div className="hero-actions hero-secondary-action">
          <a className="text-link" href={repositoryURL}>查看源码 <span aria-hidden="true">→</span></a>
        </div>

        <figure className="product-figure">
          <Image
            className="product-image product-image-light"
            src={`${basePath}/tunnelful-window-v0.1.10.png`}
            width={2240}
            height={1560}
            alt="Tunnelful 0.1.10 浅色主窗口：左侧按状态、配置与诊断分组，右侧概览本地进程、Cloudflare Edge、源站与运行环境。"
            priority
            unoptimized
          />
          <Image
            className="product-image product-image-dark"
            src={`${basePath}/tunnelful-window-dark-v0.1.10.png`}
            width={2240}
            height={1560}
            alt="Tunnelful 0.1.10 深色主窗口：左侧按状态、配置与诊断分组，右侧概览本地进程、Cloudflare Edge、源站与运行环境。"
            priority
            unoptimized
          />
          <figcaption>
            原生侧栏按状态、配置与诊断分组，集中查看 Tunnel、发布、Ingress、环境与日志。
          </figcaption>
        </figure>
      </section>

      <section className="features" id="features" aria-labelledby="features-title">
        <header className="section-heading">
          <p className="eyebrow">为日常使用而收敛</p>
          <h2 id="features-title">少一点命令，<br />多一点确定。</h2>
        </header>
        <div className="feature-list">
          {features.map((feature) => (
            <article className="feature-row" key={feature.label}>
              <p className="feature-label">{feature.label}</p>
              <h3>{feature.title}</h3>
              <p>{feature.description}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="trust" aria-labelledby="trust-title">
        <div className="trust-copy">
          <p className="eyebrow">本地优先 · 开源透明</p>
          <h2 id="trust-title">
            <span className="trust-title-line">配置留在本机，</span>
            <span className="trust-title-line">行为公开可查。</span>
          </h2>
        </div>
        <div className="trust-details">
          <p>
            Tunnelful 不包含遥测、广告或分析 SDK。命令通过参数数组直接执行，
            日志会尽力遮罩令牌与用户目录。
          </p>
          <p>
            Tunnel credentials 只检查文件元数据；cert.pem 仅在本机校验结构。
            只有在你单独确认后，应用才会调用官方 CLI 修改远端 DNS。
          </p>
          <p>
            项目采用 Apache-2.0 许可。每条命令、每次配置写入与当前限制都能在源码中检查。
          </p>
          <a className="text-link" href={`${repositoryURL}/blob/main/SECURITY.md`}>
            阅读安全说明 <span aria-hidden="true">→</span>
          </a>
        </div>
      </section>

      <section className="final-cta" aria-labelledby="download-title">
        <Image
          src={`${basePath}/tunnelful-icon.png`}
          width={76}
          height={76}
          alt=""
          aria-hidden="true"
          unoptimized
        />
        <h2 id="download-title">让 Tunnel 回到 Mac 的使用方式。</h2>
        <p>免费、开源。分别为 Apple 芯片与 Intel Mac 提供原生安装包。</p>
        <a className="button button-primary" href="#downloads">选择 Tunnelful 0.1.10</a>
        <a className="release-link" href={releasesURL}>查看发布说明</a>
      </section>

      <footer className="site-footer">
        <Brand />
        <p>
          独立开源项目，与 Cloudflare, Inc. 不存在隶属、合作、赞助或背书关系。
        </p>
        <div>
          <a href={repositoryURL}>源码</a>
          <a href={`${repositoryURL}/issues`}>问题反馈</a>
        </div>
      </footer>
    </main>
  );
}
