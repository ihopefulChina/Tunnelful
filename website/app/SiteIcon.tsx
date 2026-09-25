import Image from 'next/image';

const basePath = process.env.TUNNELFUL_PAGES === '1' ? '/Tunnelful' : '';

export default function SiteIcon({
  size,
  priority = false,
}: {
  size: number;
  priority?: boolean;
}) {
  return (
    <span className="site-icon" style={{ width: size, height: size }}>
      <Image
        className="site-icon-light"
        src={`${basePath}/tunnelful-icon.png`}
        width={size}
        height={size}
        alt=""
        aria-hidden="true"
        priority={priority}
        unoptimized
      />
      <Image
        className="site-icon-dark"
        src={`${basePath}/tunnelful-icon-dark.png`}
        width={size}
        height={size}
        alt=""
        aria-hidden="true"
        unoptimized
      />
    </span>
  );
}
