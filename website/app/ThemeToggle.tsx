'use client';

import { useSyncExternalStore } from 'react';

declare global {
  interface WindowEventMap {
    'tunnelful-theme': Event;
  }
}

export type SiteTheme = 'system' | 'light' | 'dark';

const storageKey = 'tunnelful-theme';

function isTheme(value: string | null): value is SiteTheme {
  return value === 'system' || value === 'light' || value === 'dark';
}

export function readStoredTheme(): SiteTheme {
  try {
    const stored = window.localStorage.getItem(storageKey);
    return isTheme(stored) ? stored : 'system';
  } catch {
    return 'system';
  }
}

export function applyTheme(theme: SiteTheme) {
  if (theme === 'system') {
    document.documentElement.removeAttribute('data-theme');
  } else {
    document.documentElement.setAttribute('data-theme', theme);
  }
  window.dispatchEvent(new Event('tunnelful-theme'));
}

function themeLabel(theme: SiteTheme) {
  switch (theme) {
    case 'light':
      return '浅色';
    case 'dark':
      return '深色';
    default:
      return '跟随系统';
  }
}

function nextTheme(theme: SiteTheme): SiteTheme {
  if (theme === 'system') return 'light';
  if (theme === 'light') return 'dark';
  return 'system';
}

function subscribeTheme(onChange: () => void) {
  window.addEventListener('storage', onChange);
  window.addEventListener('tunnelful-theme', onChange);
  return () => {
    window.removeEventListener('storage', onChange);
    window.removeEventListener('tunnelful-theme', onChange);
  };
}

export default function ThemeToggle() {
  const theme = useSyncExternalStore<SiteTheme>(
    subscribeTheme,
    readStoredTheme,
    (): SiteTheme => 'system',
  );

  const cycleTheme = () => {
    const next = nextTheme(theme);
    try {
      window.localStorage.setItem(storageKey, next);
    } catch {
      // Ignore private-mode storage failures; the session theme still applies.
    }
    applyTheme(next);
  };

  return (
    <button
      type="button"
      className="theme-toggle"
      onClick={cycleTheme}
      aria-label={`外观：${themeLabel(theme)}，点击切换`}
      title={`外观：${themeLabel(theme)}`}
    >
      <span className="theme-toggle-icon" aria-hidden="true">
        {theme === 'dark' ? (
          <MoonIcon />
        ) : theme === 'light' ? (
          <SunIcon />
        ) : (
          <SystemIcon />
        )}
      </span>
      <span className="theme-toggle-label">{themeLabel(theme)}</span>
    </button>
  );
}

function SunIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" fill="none">
      <circle cx="8" cy="8" r="2.6" stroke="currentColor" strokeWidth="1.4" />
      <path
        d="M8 1.6v1.5M8 12.9v1.5M1.6 8h1.5M12.9 8h1.5M3.4 3.4l1.1 1.1M11.5 11.5l1.1 1.1M3.4 12.6l1.1-1.1M11.5 4.5l1.1-1.1"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" fill="none">
      <path
        d="M13.2 10.1A5.4 5.4 0 0 1 5.9 2.8 5.5 5.5 0 1 0 13.2 10.1Z"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function SystemIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" fill="none">
      <circle cx="8" cy="8" r="5.2" stroke="currentColor" strokeWidth="1.4" />
      <path d="M8 2.8v10.4" stroke="currentColor" strokeWidth="1.4" />
      <path d="M8 2.8a5.2 5.2 0 0 1 0 10.4Z" fill="currentColor" />
    </svg>
  );
}
