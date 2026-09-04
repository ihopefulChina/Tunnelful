'use client';

import { useEffect, useState } from 'react';

type Architecture = 'arm64' | 'x86_64' | 'unknown';
type DetectionSource = 'pending' | 'ua-ch' | 'webgl' | 'unknown' | 'non-mac';

type ArchitectureDetection = {
  architecture: Architecture;
  source: DetectionSource;
};

type NavigatorWithUserAgentData = Navigator & {
  userAgentData?: {
    platform?: string;
    getHighEntropyValues?: (
      hints: string[],
    ) => Promise<{ architecture?: string; platform?: string }>;
  };
};

const armDownloadURL =
  'https://github.com/ihopefulChina/Tunnelful/releases/download/v0.1.6/Tunnelful-0.1.6-arm64.dmg';
const intelDownloadURL =
  'https://github.com/ihopefulChina/Tunnelful/releases/download/v0.1.6/Tunnelful-0.1.6-x86_64.dmg';

function normalizedArchitecture(value?: string): Architecture {
  const architecture = value?.toLowerCase();
  if (architecture === 'arm' || architecture === 'arm64' || architecture === 'aarch64') {
    return 'arm64';
  }
  if (architecture === 'x86' || architecture === 'x86_64' || architecture === 'amd64') {
    return 'x86_64';
  }
  return 'unknown';
}

function architectureFromWebGL(): Architecture {
  try {
    const canvas = document.createElement('canvas');
    const context = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
    if (!(context instanceof WebGLRenderingContext)) return 'unknown';

    const extension = context.getExtension('WEBGL_debug_renderer_info');
    if (!extension) return 'unknown';
    const renderer = String(context.getParameter(extension.UNMASKED_RENDERER_WEBGL)).toLowerCase();

    if (/apple (m\d|gpu)/.test(renderer)) return 'arm64';
    if (renderer.includes('intel')) return 'x86_64';
  } catch {
    // Browsers may intentionally hide GPU details. In that case, do not guess.
  }
  return 'unknown';
}

function isMacBrowser(navigatorWithHints: NavigatorWithUserAgentData): boolean {
  const hintedPlatform = navigatorWithHints.userAgentData?.platform?.toLowerCase();
  if (hintedPlatform) return hintedPlatform === 'macos';

  const reportsMac =
    navigatorWithHints.platform.toLowerCase().startsWith('mac') ||
    navigatorWithHints.userAgent.includes('Macintosh');
  return reportsMac && navigatorWithHints.maxTouchPoints <= 1;
}

async function detectArchitecture(): Promise<ArchitectureDetection> {
  const navigatorWithHints = navigator as NavigatorWithUserAgentData;
  if (!isMacBrowser(navigatorWithHints)) {
    return { architecture: 'unknown', source: 'non-mac' };
  }

  try {
    const values = await navigatorWithHints.userAgentData?.getHighEntropyValues?.([
      'architecture',
      'platform',
    ]);
    const hintedArchitecture = normalizedArchitecture(values?.architecture);
    if (hintedArchitecture !== 'unknown') {
      return { architecture: hintedArchitecture, source: 'ua-ch' };
    }
  } catch {
    // Continue with the local graphics capability check.
  }

  const graphicsArchitecture = architectureFromWebGL();
  return graphicsArchitecture === 'unknown'
    ? { architecture: 'unknown', source: 'unknown' }
    : { architecture: graphicsArchitecture, source: 'webgl' };
}

export default function DownloadChooser() {
  const [detection, setDetection] = useState<ArchitectureDetection>({
    architecture: 'unknown',
    source: 'pending',
  });

  useEffect(() => {
    let isActive = true;
    void detectArchitecture().then((result) => {
      if (!isActive) return;
      setDetection(result);
    });
    return () => {
      isActive = false;
    };
  }, []);

  const { architecture, source } = detection;
  const detectionMessage = source === 'pending'
    ? '正在检测此 Mac 的芯片…'
    : source === 'non-mac'
      ? '请在 Mac 上下载，或按目标 Mac 的芯片手动选择。'
      : architecture === 'arm64'
        ? `${source === 'webgl' ? '根据图形硬件推测' : '浏览器报告'}这台 Mac 使用 Apple 芯片，推荐 Apple 芯片版。`
        : architecture === 'x86_64'
          ? `${source === 'webgl' ? '根据图形硬件推测' : '浏览器报告'}这台 Mac 使用 Intel 处理器，推荐 Intel 版。`
          : '浏览器未能可靠识别芯片，请在“ → 关于本机”中确认。';

  return (
    <div className="download-chooser" id="downloads">
      <fieldset className="download-options">
        <legend className="visually-hidden">选择 Tunnelful 下载版本</legend>
        <a
          className={`button ${architecture === 'arm64' ? 'button-primary' : 'button-secondary'}`}
          href={armDownloadURL}
        >
          <span>下载 Apple 芯片版</span>
          <small>arm64{architecture === 'arm64' ? ' · 推荐' : ''}</small>
        </a>
        <a
          className={`button ${architecture === 'x86_64' ? 'button-primary' : 'button-secondary'}`}
          href={intelDownloadURL}
        >
          <span>下载 Intel 版</span>
          <small>x86_64{architecture === 'x86_64' ? ' · 推荐' : ''}</small>
        </a>
      </fieldset>
      <p className="architecture-status" aria-live="polite">
        {detectionMessage}
      </p>
      <p className="compatibility">macOS 14 及更高版本</p>
      <p className="installer-note">
        尚未经过 Apple 公证；首次打开时，macOS 可能需要你在“隐私与安全性”中确认。
      </p>
    </div>
  );
}
