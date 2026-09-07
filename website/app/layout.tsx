import type { Metadata } from 'next';
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
  metadataBase: new URL('https://hippocampus-memory.briny-river-2210.chatgpt.site'),
  title: { default: 'Hippocampus | Private memory for your Mac', template: '%s | Hippocampus' },
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
        {children}
      </body>
    </html>
  );
}
