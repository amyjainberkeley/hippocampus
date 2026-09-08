import type { Metadata } from 'next';
import Link from 'next/link';
import Image from 'next/image';
import { ArrowDownToLine } from 'lucide-react';
import { MobileNavigation } from '@/components/mobile-navigation';
import { Geist, Geist_Mono } from 'next/font/google';
import './globals.css';

const geistSans = Geist({
  variable: '--font-geist-sans',
  subsets: ['latin'],
});

const geistMono = Geist_Mono({
  variable: '--font-geist-mono',
  subsets: ['latin'],
});

export const metadata: Metadata = {
  metadataBase: new URL('https://hippocampus-memory.amyjain.chatgpt.site'),
  title: { default: 'Hippocampus | Memory for your computer', template: '%s | Hippocampus' },
  description: 'A local, encrypted memory of your work. Revisit screenshots, search captured text, and bring source-linked context into your AI tools.',
  icons: { icon: '/icon.png', apple: '/icon.png' },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        <a className="skip-link" href="#main-content">Skip to content</a>
        <header className="site-header">
          <Link className="wordmark" href="/" aria-label="Hippocampus home"><Image src="/icon.png" alt="" width={34} height={34} unoptimized />Hippocampus</Link>
          <nav className="desktop-nav" aria-label="Main navigation"><Link href="/setup">Setup</Link><Link href="/privacy">Privacy</Link><Link className="nav-download" href="/download">Mac early access <ArrowDownToLine size={15} /></Link></nav>
          <MobileNavigation />
        </header>
        {children}
        <footer className="site-footer content-width"><Link href="/">Hippocampus</Link><div><Link href="/download">Release status</Link><Link href="/privacy">Privacy</Link><a href="https://github.com/amyjainberkeley/hippocampus/tree/codex/hippocampus-v1">GitHub</a></div><span className="fine">Local-first personal memory.</span></footer>
      </body>
    </html>
  );
}
