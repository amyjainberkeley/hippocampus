import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';
export const metadata = { title: 'Privacy and control' };

export default function Privacy() {
  return <main id="main-content" className="document">
    <Link className="text-link" href="/"><ArrowLeft size={16} />Hippocampus</Link>
    <h1>Privacy and control</h1>
    <p>This is a product privacy overview for early access, not a promise of perfect capture, filtering, or deletion.</p>
    <h2>On your Mac.</h2><p>Hippocampus stores its encrypted memory under <code>~/Library/Application Support/MCI</code>. Screenshots, extracted text, and saved briefs are local. The app uses the macOS Keychain for its encryption key.</p>
    <h2>Permission is a choice.</h2><p>Capture requires your Screen Recording and Accessibility permissions. You can pause capture, exclude apps, choose retention, and delete memories. Revoking access in macOS stops that access; it does not delete previously stored memories.</p><p>Privacy checks can miss sensitive material. Exclude sensitive apps and pause before opening information you do not want remembered. Private-browser and permission-recovery behavior are still undergoing qualification.</p>
    <h2>Sharing is a separate action.</h2><p>Local OCR and extractive briefs do not need a remote AI service. When you copy, export, or connect an external agent, selected context may be handled under that provider&apos;s policies. Review what you share.</p>
    <h2>Deletion has limits.</h2><p>Removing the app alone does not remove its memory folder. Use the deletion controls in the app for stored memories. Copies in exports, backups, or other tools are separate; deletion is not a forensic-erasure guarantee.</p>
    <h2>About this website.</h2><p>This site contains no memory-upload form, advertising tracker, or newsletter signup. Its hosting provider still processes web requests and may keep operational logs. Public installers, when available, will be linked from the release host. App update checks also make network requests.</p>
    <p>Final distribution terms and a support channel will accompany the public release.</p>
    <p><Link href="/setup">Back to setup</Link></p>
  </main>;
}
