import Link from 'next/link';
import { ArrowLeft, Check, Circle } from 'lucide-react';
export const metadata = { title: 'Mac early access' };

export default function Download() {
  return <main className="document">
    <Link className="text-link" href="/"><ArrowLeft size={16} />Hippocampus</Link>
    <h1>Hippocampus for Mac.</h1>
    <p>Local evidence memory. Apple Silicon. macOS 14 or later.</p>
    <div className="notice"><p><strong>Public download is not ready yet.</strong></p><p>The current installer is signed and notarized, but independent installation checks and distribution packaging are still in progress. There is no account or payment required to read the setup guide.</p></div>
    <Link className="button secondary" href="/setup">Read the setup guide</Link>
    <h2>What's working in early access.</h2>
    <ul className="release-list"><li><Check size={17} />Local screen capture and encrypted screenshot storage</li><li><Check size={17} />Search, timeline, visual episodes, and source inspection</li><li><Check size={17} />Extractive daily drafts and bounded context exports</li><li><Check size={17} />Optional source-cited agent context</li></ul>
    <h2>Before public downloads open.</h2>
    <ul className="release-list"><li><Circle size={15} />Independent Mac installation and update checks</li><li><Circle size={15} />Final license notices, terms, and model packaging</li><li><Circle size={15} />Published, verified installer and release metadata</li></ul>
    <h2>What this release does not promise.</h2><p>OCR can misread text. Daily briefs are drafts. Verified answers, automatic commitment tracking, measured working time, and multi-device sync are not included. Overnight and browser-privacy qualification are still in progress.</p>
    <p className="fine">Release status reviewed September 6, 2026. Product screenshot uses synthetic demonstration data.</p>
  </main>;
}
