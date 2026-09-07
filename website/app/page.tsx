import Link from 'next/link';
import Image from 'next/image';
import { ArrowDownToLine, ArrowUpRight, History, Search, FileText, Terminal } from 'lucide-react';

const source = 'https://github.com/amyjainberkeley/hippocampus/tree/codex/hippocampus-v1';

export default function Home() {
  return (
    <main id="main-content">
      <section className="product-intro content-width" aria-labelledby="product-title">
        <p className="section-kicker">Local-first memory for macOS</p>
        <h1 id="product-title">Hippocampus</h1>
        <p className="product-purpose">Memory for your computer.</p>
        <p className="product-description">Keep a history of the work on your screen. Find it again, make sense of it, and bring the relevant context to your AI.</p>
        <div className="product-actions">
          <Link className="button primary" href="/download"><ArrowDownToLine size={17} />Mac early access</Link>
          <a className="text-link" href={source}>Explore the source <ArrowUpRight size={16} /></a>
        </div>
        <p className="fine">Opt-in capture. Stored locally. Yours to delete.</p>
      </section>

      <section id="memory" className="product-evidence" aria-label="Inside Hippocampus">
        <figure className="content-width">
          <Image src="/product-recall.jpeg" width={1057} height={710} alt="Hippocampus Text search with three relevant memories, a full-text detail, and the copy-agent-context action. This native app example uses synthetic work data." priority unoptimized />
          <figcaption><span>A local record, with the sources attached.</span><span>Native Mac app · Synthetic example</span></figcaption>
        </figure>
      </section>

      <section className="work-outcomes content-width" aria-labelledby="outcomes-title">
        <h2 id="outcomes-title">What your memory gives you</h2>
        <div className="outcome-grid">
          <article><Search size={21} strokeWidth={1.5} /><h3>Find something you saw</h3><p>Search captured words and return to the screenshot, app, and moment they came from.</p></article>
          <article><History size={21} strokeWidth={1.5} /><h3>Pick up a piece of work</h3><p>Revisit your timeline and work sessions to recover the context around a task.</p></article>
          <article><FileText size={21} strokeWidth={1.5} /><h3>Review your day</h3><p>Read a source-linked daily draft. Follow a detail back to the record, or copy the whole brief.</p></article>
          <article><Terminal size={21} strokeWidth={1.5} /><h3>Give an agent context</h3><p>Bring relevant memory into Claude, Codex, or another connected tool, with references it can follow.</p></article>
        </div>
      </section>

      <section className="engineering-band" aria-labelledby="engineering-title"><div className="content-width engineering-content">
        <div><p className="section-kicker">Built around your own record</p><h2 id="engineering-title">Useful context.<br />Inspectable origins.</h2></div>
        <div><p>Text recognition runs on your Mac. Screenshots and text are encrypted locally. A brief keeps its source references; an agent receives a bounded selection, not your entire history.</p>
          <p className="engineering-direction">The aim is a computer that can build on your work, with memory you can inspect and control.</p>
          <a className="text-link" href={`${source}/docs/guide`}>How it is built <ArrowUpRight size={16} /></a>
          <a className="text-link" href={`${source}/docs/guide/development-history.md`}>Development history <ArrowUpRight size={16} /></a>
        </div>
      </div></section>

      <section className="questions content-width" aria-labelledby="questions-title">
        <h2 id="questions-title">A few practical details</h2>
        <details><summary>What does it capture?</summary><p>The focused, permitted window after you opt in. Not unopened tabs, off-screen content, or every background window. You can pause capture, exclude apps, and delete memory.</p></details>
        <details><summary>What stays on my Mac?</summary><p>Captured screenshots, text, and briefs stay in encrypted local storage. Context you choose to export or make available to an external AI client follows that client&apos;s policies. <Link href="/privacy">Privacy details</Link></p></details>
        <details><summary>How should I use a brief?</summary><p>As a draft with a way back to the evidence. Text recognition can miss words. Seeing a task on screen does not prove it was completed, and gaps in capture are not a record of time away.</p></details>
        <details><summary>Where can I try it or contribute?</summary><p><Link href="/download">Mac early access</Link> has the current availability and installation requirements. The <a href={source}>source repository</a> includes the build instructions, tests, architecture, and development history.</p></details>
      </section>
    </main>
  );
}
