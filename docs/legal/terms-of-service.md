<!--
Product-behavior review: 2026-09-01, reconciled against docs/STATUS.md.
Legal owner review remains required before public distribution. Do not add
security, deletion, sync, or hardware guarantees without release evidence.
-->

# Hippocampus Software License Terms

**Effective date:** September 1, 2026

**Last updated:** September 1, 2026

These terms apply to the Hippocampus desktop application. By installing or
using Hippocampus, you agree to these terms. If you do not agree, do not install
or use the software.

## 1. What Hippocampus does

Hippocampus is a local-first macOS application that can capture screen and
workflow context when you enable capture. It processes captured content on the
Mac using OCR and local models and stores memory data in a local SQLCipher
database.

The local memory pipeline does not upload captured content to a Hippocampus
service. Update checks and diagnostics you explicitly enable may contact their
stated services. Content you intentionally send to a connected external tool or
model is governed by that provider's terms and privacy practices.

## 2. License

Subject to these terms and the licenses supplied with the software, you may
install and use Hippocampus on macOS devices you own or control for personal or
internal business purposes.

You may not use Hippocampus to violate applicable law, capture content you do
not have permission to record, monitor another person without their knowledge
and consent, or remove notices that applicable licenses require.

## 3. Your data and local custody

You retain your rights in the content Hippocampus processes for you. The local
database, extracted text, embeddings, and captured artifacts remain on your Mac
unless you direct another tool to receive them.

The database is encrypted with SQLCipher. The database key is stored in a
non-synchronizing macOS Keychain item for use by the shipped local components.
This design reduces exposure but does not make the key non-exportable and does
not protect against every process running as the same macOS user. Backups,
exports, external tools, and copies you create are outside the application's
local deletion boundary.

## 4. Capture controls and sensitive content

Screen capture is off by default and requires macOS Screen Recording permission
plus an explicit in-app setting. Hippocampus includes controls intended to
exclude or suppress sensitive surfaces. Those controls can miss content. You
are responsible for reviewing capture settings, blocked applications, and the
content visible on your screen.

## 5. Retention and deletion

When a retention rule expires or you delete a memory, Hippocampus removes the
corresponding database rows and compacts local database storage. Compaction can
reclaim database space, but deletion is not a guarantee of forensic erasure
from storage media, backups, exports, or copies held by other tools.

To remove the local product and its primary data:

1. Quit Hippocampus.
2. Delete the Hippocampus application.
3. Delete `~/Library/Application Support/MCI/`.
4. Optionally delete `~/Library/Logs/MCI/`.

## 6. Security and availability limitations

No software security control is perfect. Hippocampus does not warrant that
capture filtering will identify every sensitive surface, that OCR or search
results will be complete or accurate, that encryption will be free of
vulnerabilities, or that the software will operate without interruption or data
loss. Keep backups appropriate for your needs and protect access to your Mac
account.

## 7. Warranty disclaimer

TO THE MAXIMUM EXTENT PERMITTED BY LAW, THE SOFTWARE IS PROVIDED "AS IS" AND
"AS AVAILABLE," WITHOUT WARRANTIES OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.

## 8. Limitation of liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, HIPPOCAMPUS AND ITS CONTRIBUTORS WILL
NOT BE LIABLE FOR INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY, OR
PUNITIVE DAMAGES, OR FOR LOSS OF PROFITS, DATA, USE, OR GOODWILL, ARISING FROM
YOUR USE OF OR INABILITY TO USE THE SOFTWARE.

TO THE MAXIMUM EXTENT PERMITTED BY LAW, TOTAL LIABILITY FOR CLAIMS RELATED TO
THE SOFTWARE WILL NOT EXCEED THE GREATER OF THE AMOUNT YOU PAID FOR THE SOFTWARE
IN THE TWELVE MONTHS BEFORE THE CLAIM OR FIFTY U.S. DOLLARS.

## 9. Termination

You may stop using Hippocampus at any time. If you violate these terms, your
license may terminate. Provisions concerning ownership, disclaimers,
limitations of liability, and applicable law survive termination.

## 10. Updates

Hippocampus may offer signed updates through Sparkle. You may disable automatic
update checks in the application. Update verification reduces tampering risk but
does not create an absolute security guarantee.

## 11. General terms

If a provision of these terms is unenforceable, the remaining provisions remain
in effect. Failure to enforce a provision is not a waiver. You may not transfer
these terms where applicable law prohibits the transfer restriction.

## 12. Contact

Questions about these terms may be sent to `legal@hippocampus.ai`.

The engineering codename MCI means Memory Context Interface and refers to the
same local Hippocampus software covered by these terms.
