'use client';

import { useEffect } from 'react';

function isModifiedClick(event: MouseEvent) {
  return event.metaKey || event.ctrlKey || event.shiftKey || event.altKey;
}

function decodeHash(hash: string) {
  const raw = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!raw) return '';
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

function focusHashTarget(id: string) {
  const destination = id ? document.getElementById(id) : null;
  if (!destination) return;
  if (!destination.hasAttribute('tabindex')) {
    destination.tabIndex = -1;
  }
  destination.focus({ preventScroll: true });
}

export default function HashNavigation() {
  useEffect(() => {
    const onClick = (event: MouseEvent) => {
      if (
        event.defaultPrevented ||
        event.button !== 0 ||
        isModifiedClick(event)
      ) {
        return;
      }

      const eventTarget = event.target;
      if (!(eventTarget instanceof Element)) return;

      const link = eventTarget.closest('a[href^="#"]');
      if (
        !(link instanceof HTMLAnchorElement) ||
        link.getAttribute('href') === '#'
      ) {
        return;
      }

      const id = decodeHash(link.hash);
      if (!id || !document.getElementById(id)) return;

      if (event.detail === 0) {
        focusHashTarget(id);
      }
    };

    document.addEventListener('click', onClick);
    return () => document.removeEventListener('click', onClick);
  }, []);

  return null;
}
