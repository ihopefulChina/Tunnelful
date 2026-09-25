import type { Metadata, Viewport } from 'next';

import HashNavigation from './HashNavigation';
import './globals.css';

const basePath = process.env.TUNNELFUL_PAGES === '1' ? '/Tunnelful' : '';

export const metadata: Metadata = {
  metadataBase: new URL('https://ihopefulchina.github.io/Tunnelful/'),
  title: 'Tunnelful — Cloudflare Tunnel 的原生 Mac 控制工具',
  description:
    '安全编辑 Ingress、预览并确认 DNS 路由，分别查看进程、Edge 与源站状态。窗口关闭后仍常驻菜单栏。',
  icons: {
    icon: [
      {
        url: `${basePath}/tunnelful-icon.png`,
        media: '(prefers-color-scheme: light)',
      },
      {
        url: `${basePath}/tunnelful-icon-dark.png`,
        media: '(prefers-color-scheme: dark)',
      },
    ],
  },
};

export const viewport: Viewport = {
  viewportFit: 'cover',
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: '#f8f8f5' },
    { media: '(prefers-color-scheme: dark)', color: '#181816' },
  ],
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN" suppressHydrationWarning>
      <body>
        <script
          dangerouslySetInnerHTML={{
            __html:
              "(function(){try{var t=localStorage.getItem('tunnelful-theme');if(t==='light'||t==='dark'){document.documentElement.setAttribute('data-theme',t);}var dark=t==='dark'||((!t||t==='system')&&window.matchMedia('(prefers-color-scheme: dark)').matches);document.querySelectorAll('meta[name=\"theme-color\"]').forEach(function(m){m.setAttribute('content',dark?'#181816':'#f8f8f5');});}catch(e){}})();",
          }}
        />
        <HashNavigation />
        {children}
      </body>
    </html>
  );
}
