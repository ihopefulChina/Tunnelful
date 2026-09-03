import type { Metadata } from 'next';

import './globals.css';

const basePath = process.env.TUNNELFUL_PAGES === '1' ? '/Tunnelful' : '';

export const metadata: Metadata = {
  metadataBase: new URL('https://ihopefulchina.github.io/Tunnelful/'),
  title: 'Tunnelful — Cloudflare Tunnel 的原生 Mac 控制工具',
  description:
    '编辑 Ingress、确认并执行 DNS 路由命令，以及启动或停止 Tunnel。窗口关闭后仍常驻菜单栏。',
  icons: {
    icon: `${basePath}/tunnelful-icon.png`,
  },
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
              "(function(){try{var t=localStorage.getItem('tunnelful-theme');if(t==='light'||t==='dark'){document.documentElement.setAttribute('data-theme',t);}}catch(e){}})();",
          }}
        />
        {children}
      </body>
    </html>
  );
}
