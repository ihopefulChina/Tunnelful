import Image from 'next/image';

import DownloadChooser from './DownloadChooser';

const repositoryURL = 'https://github.com/ihopefulChina/Tunnelful';
const releasesURL = `${repositoryURL}/releases/tag/v0.1.0`;

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
    label: '状态',
    title: '进程、Edge 与源站各自可见。',
    description:
      '不再用一个绿色圆点概括所有问题。连接正常，不代表本地服务一定可达。',
  },
  {
    label: '常驻',
    title: '关掉窗口，隧道继续运行。',
    description:
      '窗口打开时使用完整 macOS 系统菜单；关闭后隐藏 Dock 图标并留在菜单栏。还可选择登录 Mac 时打开，并在应用启动后运行当前 Tunnel。',
  },
  {
    label: '更新',
    title: '新版本，由你决定何时安装。',
    description:
      '在应用内检查正式 GitHub Release；发现更新后，由你确认并打开官方下载页。',
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
            <a className="nav-download" href="#downloads">下载</a>
          </div>
        </nav>
      </header>

      <section className="hero" aria-labelledby="hero-title">
        <p className="eyebrow">macOS 菜单栏工具</p>
        <h1 id="hero-title">
          把 Cloudflare Tunnel，
          <span>交给一个真正的 Mac 应用。</span>
        </h1>
        <p className="hero-description">
          编辑 Ingress、确认并执行 DNS 路由命令，以及启动或停止 Tunnel。
          窗口关闭后仍常驻菜单栏。
        </p>
        <DownloadChooser />
        <div className="hero-actions hero-secondary-action">
          <a className="text-link" href={repositoryURL}>查看源码 <span aria-hidden="true">→</span></a>
        </div>

        <figure className="product-figure">
          <picture className="product-picture">
            <source
              media="(prefers-color-scheme: dark)"
              srcSet={`${basePath}/tunnelful-window-dark-v0.1.0.png`}
            />
            <Image
              className="product-image"
              src={`${basePath}/tunnelful-window-v0.1.0.png`}
              width={2240}
              height={1560}
              alt="Tunnelful 原生主窗口：左侧为功能导航，右侧概览本地进程、Cloudflare Edge、源站与运行环境。"
              priority
              unoptimized
            />
          </picture>
          <figcaption>
            一个原生窗口，集中查看状态、Tunnel、发布、Ingress 配置、环境与日志。
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
        <a className="button button-primary" href="#downloads">选择 Tunnelful 0.1.0</a>
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
