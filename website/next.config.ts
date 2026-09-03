import type { NextConfig } from 'next';

const isGitHubPages = process.env.TUNNELFUL_PAGES === '1';

const nextConfig: NextConfig = {
  output: 'export',
  trailingSlash: true,
  basePath: isGitHubPages ? '/Tunnelful' : '',
};

export default nextConfig;
