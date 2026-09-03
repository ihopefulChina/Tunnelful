import Image from 'next/image';

const basePath = process.env.TUNNELFUL_PAGES === '1' ? '/Tunnelful' : '';

export default function NotFound() {
  return (
    <main className="not-found-shell">
      <section className="not-found" aria-labelledby="not-found-title">
        <Image
          src={`${basePath}/tunnelful-icon.png`}
          width={72}
          height={72}
          alt=""
          aria-hidden="true"
          unoptimized
        />
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
