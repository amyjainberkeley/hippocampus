import Link from 'next/link';
import Image from 'next/image';
import { ArrowDownToLine, ArrowRight, Brain, Check, Eye, FileText, LockKeyhole, ScanText, Terminal } from 'lucide-react';

export default function Home() {
  return (
    <main id="main-content">
      <section className="hero" aria-labelledby="hero-title">
        <Image className="hero-art" src="/memory-layers.jpg" width={1536} height={1024} alt="Illustration of transparent memory layers connected around a brain." priority unoptimized />
        <div className="hero-copy">
          <p className="eyebrow">Personal context. Stored locally.</p>
          <h1 id="hero-title">Hippocampus</h1>
          <p className="hero-description">Local-first memory for<br />your Mac and your AI.</p>
          <p className="hero-detail">Records permitted screen context, turns it into searchable memory, and shares the sources you choose.</p>
          <div className="hero-actions"><Link className="button primary" href="/download"><ArrowDownToLine size={18} />Mac early access</Link><a className="text-link" href="#memory">Explore the memory layer <ArrowRight size={16} /></a></div>
          <p className="fine">Encrypted on your Mac. No Hippocampus cloud copy.</p>
        </div>
      </section>

      <section id="memory" className="intro content-width" aria-labelledby="memory-title">
        <p className="section-kicker">One memory. Two ways to use it.</p>
        <h2 id="memory-title">Find it yourself.<br />Give your AI the context.</h2>
        <div className="principles">
          <article><ScanText size={25} strokeWidth={1.5} /><h3>Search what you saw</h3><p>Find captured text, revisit your timeline, and open the original screenshot. Check the source, not just a summary.</p></article>
          <article><FileText size={25} strokeWidth={1.5} /><h3>Review your work</h3><p>Browse work sessions and daily drafts. Copy a day&apos;s summary with its source references, not one memory at a time.</p></article>
          <article><Terminal size={25} strokeWidth={1.5} /><h3>Brief your AI</h3><p>Bring selected, source-linked context into Claude or Codex. Optional agent connections can retrieve local memory when you ask.</p></article>
        </div>
      </section>

      <section className="memory-flow" aria-labelledby="flow-title"><div className="content-width">
        <div className="section-heading"><div><p className="section-kicker">The memory layer</p><h2 id="flow-title">From visible work<br />to usable context.</h2></div><p>Screen context is a starting point. A useful memory also needs a source, a timestamp, and a clear boundary around what it knows.</p></div>
        <ol className="flow-steps">
          <li><span className="step-number">01</span><Eye size={23} strokeWidth={1.5} /><h3>Capture</h3><p>Permitted focused windows, after you opt in. Sensitive or uncertain sources can be skipped.</p></li>
          <li><span className="step-number">02</span><ScanText size={23} strokeWidth={1.5} /><h3>Read</h3><p>On-device text recognition turns visible words into searchable text. The screenshot stays alongside it.</p></li>
          <li><span className="step-number">03</span><Brain size={23} strokeWidth={1.5} /><h3>Remember</h3><p>Encrypted local storage keeps captured moments, sessions, and source-linked daily drafts.</p></li>
          <li><span className="step-number">04</span><Terminal size={23} strokeWidth={1.5} /><h3>Use</h3><p>Search for yourself or share a bounded context packet with your AI. You choose what leaves your Mac.</p></li>
        </ol>
      </div></section>

      <section className="control content-width" aria-labelledby="control-title">
        <LockKeyhole size={28} strokeWidth={1.4} /><p className="section-kicker">Personal memory, not employee monitoring</p>
        <h2 id="control-title">Visibility for you.<br />Control by you.</h2>
        <p className="section-description">No manager dashboard. No productivity score. Remembering your work should help you, not turn every app you open into a judgment.</p>
        <ul className="control-list"><li><Check size={17} />Opt-in capture</li><li><Check size={17} />Pause and exclusions</li><li><Check size={17} />Retention and deletion</li><li><Check size={17} />Review before sharing</li></ul>
        <Link className="text-link" href="/privacy">Read the privacy details <ArrowRight size={16} /></Link>
      </section>

      <section className="vision-band" aria-labelledby="vision-title"><div className="content-width">
        <p className="section-kicker">The direction</p><h2 id="vision-title">A computer that can<br />build on your work.</h2>
        <p>Memory should connect what you planned, what changed, and what needs your attention. The longer-term goal is a personal context layer that helps your tools act with a better understanding of your work.</p>
        <p className="vision-status"><strong>Still in development:</strong> richer understanding, reviewable commitments, and work insights based on measured activity. Today&apos;s drafts are not verified answers or a complete account of your day.</p>
        <a className="text-link" href="https://github.com/amyjainberkeley/hippocampus/tree/codex/hippocampus-v1">Follow development on GitHub <ArrowRight size={16} /></a>
      </div></section>

      <section className="questions content-width" aria-labelledby="questions-title">
        <h2 id="questions-title">Before you start</h2>
        <details><summary>Does it record my entire screen?</summary><p>Currently, Hippocampus captures the focused, permitted window. It does not read unopened tabs, off-screen content, or every background window. This limits accidental capture of private material beside your work. Broader coverage needs its own consent and privacy checks.</p></details>
        <details><summary>Does my memory stay on my Mac?</summary><p>Captured screenshots, text, and briefs are stored locally in encrypted form. When you export context or connect an external AI client, the selected text can leave your Mac under that client&apos;s policies. Local storage does not make an external AI service local.</p></details>
        <details><summary>Can I rely on the text and summaries?</summary><p>Use the source to verify important details. OCR can omit or misread words, and daily briefs are extractive drafts. A captured statement is evidence of what appeared on screen, not proof that it is true or that a task was completed.</p></details>
        <details><summary>Can I download it now?</summary><p>The app is in early access. Public downloads are pending installation, privacy, and distribution checks. The <Link href="/download">release page</Link> explains what is available and what is still being qualified.</p></details>
      </section>
    </main>
  );
}
