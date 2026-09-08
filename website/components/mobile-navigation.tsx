'use client';

import { useRef, type KeyboardEvent } from 'react';
import Link from 'next/link';
import { ChevronDown } from 'lucide-react';

export function MobileNavigation() {
  const menu = useRef<HTMLDetailsElement>(null);
  const close = () => { if (menu.current) menu.current.open = false; };
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (event.key === 'Escape') {
      close();
      menu.current?.querySelector('summary')?.focus();
    }
  };

  return (
    <details className="mobile-nav" ref={menu}>
      <summary onKeyDown={onKeyDown}>Menu <ChevronDown size={16} /></summary>
      <nav aria-label="Mobile navigation">
        <Link href="/setup" onClick={close} onKeyDown={onKeyDown}>Setup</Link>
        <Link href="/privacy" onClick={close} onKeyDown={onKeyDown}>Privacy</Link>
        <Link href="/download" onClick={close} onKeyDown={onKeyDown}>Mac early access</Link>
      </nav>
    </details>
  );
}
