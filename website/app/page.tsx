import Link from 'next/link';
import Image from 'next/image';
import { ArrowDownToLine, ArrowUpRight } from 'lucide-react';

const source = 'https://github.com/amyjainberkeley/hippocampus/tree/codex/hippocampus-v1';

export default function Home() {
  return (
    <main id="main-content">
      <section className="product-intro content-width" aria-labelledby="product-title">
        <h1 id="product-title">Hippocampus</h1>
        <p className="product-purpose">Memory for your Mac.</p>
        <p className="product-description">Remember your work. Find where you left off. Share the right context with the AI you choose.</p>
        <div className="product-actions">
          <Link className="button primary" href="/download"><ArrowDownToLine size={17} />Mac early access</Link>
          <a className="text-link" href={source}>View on GitHub <ArrowUpRight size={16} /></a>
        </div>
        <p className="fine">Local-first. Capture only with your permission.</p>
      </section>

      <section id="memory" className="product-evidence content-width" aria-label="The Mac app">
        <figure>
          {/* oxlint-disable-next-line next/no-html-link-for-pages -- Open a static image, not an app route. */}
          <a href="/product-daily-review.jpeg" aria-label="Open the full-size Mac app screenshot">
            <Image src="/product-daily-review.jpeg" width={1100} height={768} alt="Hippocampus Daily Review on Mac: last saved context, an observed return to an app, a capture gap, and saved images. Synthetic work data." priority unoptimized />
          </a>
          <figcaption>App screenshots use synthetic work data.</figcaption>
        </figure>
      </section>

      <section className="product-notes content-width" aria-label="About your memory">
        <div>
          <h2>A record you can return to.</h2>
          <p>Search the words you saw, revisit a work session, or review a day. Open the original screenshot when you need the detail.</p>
        </div>
        <div>
          <h2>Context you choose to share.</h2>
          <p>Bring a source-linked summary to your agent. Your captured history stays encrypted on your Mac; you choose what leaves it.</p>
        </div>
      </section>

      <section className="questions content-width" aria-label="Practical details">
        <details><summary>What is recorded?</summary><p>The focused, permitted window after you opt in. Not unopened tabs or off-screen content. Pause capture, exclude apps, or delete memory at any time. <Link href="/privacy">Privacy details</Link></p></details>
        <details><summary>Does it use a cloud AI?</summary><p>Text recognition and the built-in memory processing run on your Mac. No hosted model subscription is required. Content shared with an external AI follows that service&apos;s policies.</p></details>
        <details><summary>Can I see how it is built?</summary><p>Yes. The <a href={source}>source code</a>, <a href={`${source}/docs/guide`}>architecture</a>, and <a href={`${source}/docs/guide/development-history.md`}>development history</a> are on GitHub. The <Link href="/download">Mac release page</Link> has current availability, and the <Link href="/setup">setup guide</Link> covers installation.</p></details>
      </section>
    </main>
  );
}
