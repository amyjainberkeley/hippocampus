import Link from 'next/link';
import { ArrowDownToLine, ArrowUpRight, ScanText, ShieldCheck, Layers } from 'lucide-react';

export default function Home() {
  return (
    <>
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="Hippocampus home"><img src="/icon.png" alt="" width="30" height="30" />Hippocampus</Link>
        <nav aria-label="Main navigation"><Link href="/setup">Setup</Link><Link href="/privacy">Privacy</Link><Link className="nav-download" href="/download">Get the Mac app <ArrowDownToLine size={15} /></Link></nav>
      </header>
      <main>
        <section className="hero" aria-labelledby="hero-title">
          <div className="hero-copy">
            <p className="eyebrow">Your Mac. Your memory.</p>
            <h1 id="hero-title">Hippocampus</h1>
            <p className="hero-description">Pick up where your mind left off.<br />A private, searchable memory of your work.</p>
            <div className="hero-actions"><Link className="button primary" href="/download"><ArrowDownToLine size={18} />Get Hippocampus for Mac</Link><Link className="text-link" href="/setup">Meet your memory <ArrowUpRight size={16} /></Link></div>
            <p className="fine">Early access. Local storage. No Hippocampus account.</p>
          </div>
          <div className="hero-product"><a href="/memory-evidence.jpeg" aria-label="View the full Hippocampus product screenshot"><img src="/memory-evidence.jpeg" width="1060" height="680" alt="Hippocampus showing a saved screenshot beside its searchable text and source details. Synthetic demonstration data." fetchPriority="high" /></a></div>
        </section>
        <section className="intro content-width">
          <p className="section-kicker">A little less starting over.</p>
          <h2>The context is still here.</h2>
          <div className="principles">
            <article><ScanText size={24} strokeWidth={1.5} /><h3>Find the moment.</h3><p>Search captured text, revisit a day, and open the screenshot it came from.</p></article>
            <article><Layers size={24} strokeWidth={1.5} /><h3>Take the context with you.</h3><p>Copy a memory or a day of source-linked context into the tools you already use.</p></article>
            <article><ShieldCheck size={24} strokeWidth={1.5} /><h3>Keep it yours.</h3><p>Encrypted memory on your Mac. Explicit permissions. Pause, exclusions, and deletion controls.</p></article>
          </div>
        </section>
        <section className="setup-band"><div className="content-width"><h2>A quieter kind of memory.</h2><p>Start with your own Mac. Choose what it can remember.</p><Link className="button secondary" href="/setup">Set up Hippocampus <ArrowUpRight size={17} /></Link></div></section>
      </main>
      <footer className="site-footer content-width"><span>Hippocampus</span><div><Link href="/download">Release notes</Link><Link href="/privacy">Privacy & control</Link></div><span className="fine">Made for remembering.</span></footer>
    </>
  );
}
