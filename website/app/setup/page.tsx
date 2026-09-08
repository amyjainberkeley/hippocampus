import Link from 'next/link';
import { ArrowLeft, ArrowUpRight } from 'lucide-react';
export const metadata = { title: 'Set up your memory' };

export default function Setup() {
  return <main id="main-content" className="document">
    <Link className="text-link" href="/"><ArrowLeft size={16} />Hippocampus</Link>
    <h1>Set up Hippocampus</h1>
    <p>Setup stays on your Mac. A Hippocampus account is not required.</p>
    <div className="notice"><p>Public downloads are not available yet. This guide describes the current early-access setup.</p></div>
    <section className="step"><h2>1. Install the Mac app.</h2><p>Check the <Link href="/download">release page</Link> for the signed installer. Open the disk image, drag Hippocampus to Applications, then open it from Applications.</p><p className="fine">Apple Silicon Mac, macOS 14 or later. Intel Macs, Windows, and iPhone are not supported in this release.</p></section>
    <section className="step"><h2>2. Choose what it can remember.</h2><p>Follow the setup screens in the app. Screen Recording lets Hippocampus capture the focused, permitted window; Accessibility supports its privacy checks. Grant each permission in System Settings, then return to the app.</p><p>Keep sensitive apps excluded. Background windows, unopened tabs, and off-screen text are not captured. Browser-specific setup and optional imports are separate choices. You do not need to grant Full Disk Access for basic screen memory.</p></section>
    <section className="step"><h2>3. Check your first memory.</h2><p>After completing setup, click Get Started. Open a harmless note with a distinctive sentence. Return to Daily review and check the capture status. Search for the sentence, then open its original screenshot.</p><p>The menu-bar capture controls let you pause at any time. A permission grant alone is not proof that capture is working.</p></section>
    <section className="step"><h2>4. Bring the context with you.</h2><p>Choose a day in Daily review, then select Handoff. Review the source excerpts before copying or exporting. Paste the text into Claude, Codex, or another tool you choose. Screenshots are not included.</p><p>The app rechecks the evidence before exporting. If it changed, review the updated preview first. Optional agent connections are configured inside the app; local memory does not require an AI subscription.</p></section>
    <h2>Something not showing up?</h2>
    <ul><li><strong>No screen memory:</strong> check the capture status, your exclusions, and both required permissions. An excluded or locked screen may be intentionally skipped.</li><li><strong>Permission still says denied:</strong> confirm Hippocampus is enabled in the matching System Settings pane, return to setup, and follow any macOS request to quit and reopen.</li><li><strong>Text is wrong:</strong> OCR is imperfect. Open the screenshot to check names, numbers, punctuation, and code.</li><li><strong>No daily brief:</strong> useful memories must be saved first. Briefs are extractive drafts, not a verified account of your day.</li></ul>
    <p><Link className="text-link" href="/privacy">Privacy and control <ArrowUpRight size={16} /></Link></p>
  </main>;
}
