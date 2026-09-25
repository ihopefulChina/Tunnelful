import type { Metadata } from 'next';

import SiteIcon from './SiteIcon';

const basePath = process.env.TUNNELFUL_PAGES === '1' ? '/Tunnelful' : '';

export const metadata: Metadata = {
  title: '页面不存在 — Tunnelful',
};

export default function NotFound() {
  return (
    <main className="not-found-shell">
      <section className="not-found" aria-labelledby="not-found-title">
        <SiteIcon size={72} />
        <p className="eyebrow">404</p>
        <h1 id="not-found-title">这里没有页面。</h1>
        <p>你访问的地址不存在，或已经移动。</p>
        <a className="button button-primary" href={`${basePath}/`}>
          返回首页
        </a>
      </section>
    </main>
  );
}
