/* DMG Software License Agreement resources.
 * Auto-generated from docs/legal/terms-of-service.md.
 * Regenerate: python3 assets/installer/generate-eula.py
 *
 * Attach to DMG:
 *   hdiutil unflatten Hippocampus.dmg
 *   Rez -append assets/installer/sla.r -o Hippocampus.dmg
 *   hdiutil flatten Hippocampus.dmg
 */

data 'LPic' (5000) {
    $"0000"  /* default language */
    $"0001"  /* count */
    $"0000"  /* English */
    $"0000"  /* resource ID offset */
    $"0000"  /* reserved */
};

resource 'STR#' (5000, "English buttons") {
    {
        "English",
        "Agree",
        "Disagree",
        "Print",
        "Save\311",
        "If you agree with the terms of this license, click "
        "\"Agree\" to install the software. "
        "If you do not agree, click \"Disagree\"."
    }
};

data 'TEXT' (5000, "English") {
    "Hippocampus Software License Terms\n"
    "\n"
    "Effective date: September 1, 2026\n"
    "\n"
    "Last updated: September 1, 2026\n"
    "\n"
    "These terms apply to the Hippocampus desktop application. By installing or\n"
    "using Hippocampus, you agree to these terms. If you do not agree, do not install\n"
    "or use the software.\n"
    "\n"
    "1. What Hippocampus does\n"
    "\n"
    "Hippocampus is a local-first macOS application that can capture screen and\n"
    "workflow context when you enable capture. It processes captured content on the\n"
    "Mac using OCR and local models and stores memory data in a local SQLCipher\n"
    "database.\n"
    "\n"
    "The local memory pipeline does not upload captured content to a Hippocampus\n"
    "service. Update checks and diagnostics you explicitly enable may contact their\n"
    "stated services. Content you intentionally send to a connected external tool or\n"
    "model is governed by that provider's terms and privacy practices.\n"
    "\n"
    "2. License\n"
    "\n"
    "Subject to these terms and the licenses supplied with the software, you may\n"
    "install and use Hippocampus on macOS devices you own or control for personal or\n"
    "internal business purposes.\n"
    "\n"
    "You may not use Hippocampus to violate applicable law, capture content you do\n"
    "not have permission to record, monitor another person without their knowledge\n"
    "and consent, or remove notices that applicable licenses require.\n"
    "\n"
    "3. Your data and local custody\n"
    "\n"
    "You retain your rights in the content Hippocampus processes for you. The local\n"
    "database, extracted text, embeddings, and captured artifacts remain on your Mac\n"
    "unless you direct another tool to receive them.\n"
    "\n"
    "The database is encrypted with SQLCipher. The database key is stored in a\n"
    "non-synchronizing macOS Keychain item for use by the shipped local components.\n"
    "This design reduces exposure but does not make the key non-exportable and does\n"
    "not protect against every process running as the same macOS user. Backups,\n"
    "exports, external tools, and copies you create are outside the application's\n"
    "local deletion boundary.\n"
    "\n"
    "4. Capture controls and sensitive content\n"
    "\n"
    "Screen capture is off by default and requires macOS Screen Recording permission\n"
    "plus an explicit in-app setting. Hippocampus includes controls intended to\n"
    "exclude or suppress sensitive surfaces. Those controls can miss content. You\n"
    "are responsible for reviewing capture settings, blocked applications, and the\n"
    "content visible on your screen.\n"
    "\n"
    "5. Retention and deletion\n"
    "\n"
    "When a retention rule expires or you delete a memory, Hippocampus removes the\n"
    "corresponding database rows and compacts local database storage. Compaction can\n"
    "reclaim database space, but deletion is not a guarantee of forensic erasure\n"
    "from storage media, backups, exports, or copies held by other tools.\n"
    "\n"
    "To remove the local product and its primary data:\n"
    "\n"
    "1. Quit Hippocampus.\n"
    "2. Delete the Hippocampus application.\n"
    "3. Delete ~/Library/Application Support/MCI/.\n"
    "4. Optionally delete ~/Library/Logs/MCI/.\n"
    "\n"
    "6. Security and availability limitations\n"
    "\n"
    "No software security control is perfect. Hippocampus does not warrant that\n"
    "capture filtering will identify every sensitive surface, that OCR or search\n"
    "results will be complete or accurate, that encryption will be free of\n"
    "vulnerabilities, or that the software will operate without interruption or data\n"
    "loss. Keep backups appropriate for your needs and protect access to your Mac\n"
    "account.\n"
    "\n"
    "7. Warranty disclaimer\n"
    "\n"
    "TO THE MAXIMUM EXTENT PERMITTED BY LAW, THE SOFTWARE IS PROVIDED \"AS IS\" AND\n"
    "\"AS AVAILABLE,\" WITHOUT WARRANTIES OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING\n"
    "MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, AND NON-INFRINGEMENT.\n"
    "\n"
    "8. Limitation of liability\n"
    "\n"
    "TO THE MAXIMUM EXTENT PERMITTED BY LAW, HIPPOCAMPUS AND ITS CONTRIBUTORS WILL\n"
    "NOT BE LIABLE FOR INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, EXEMPLARY, OR\n"
    "PUNITIVE DAMAGES, OR FOR LOSS OF PROFITS, DATA, USE, OR GOODWILL, ARISING FROM\n"
    "YOUR USE OF OR INABILITY TO USE THE SOFTWARE.\n"
    "\n"
    "TO THE MAXIMUM EXTENT PERMITTED BY LAW, TOTAL LIABILITY FOR CLAIMS RELATED TO\n"
    "THE SOFTWARE WILL NOT EXCEED THE GREATER OF THE AMOUNT YOU PAID FOR THE SOFTWARE\n"
    "IN THE TWELVE MONTHS BEFORE THE CLAIM OR FIFTY U.S. DOLLARS.\n"
    "\n"
    "9. Termination\n"
    "\n"
    "You may stop using Hippocampus at any time. If you violate these terms, your\n"
    "license may terminate. Provisions concerning ownership, disclaimers,\n"
    "limitations of liability, and applicable law survive termination.\n"
    "\n"
    "10. Updates\n"
    "\n"
    "Hippocampus may offer signed updates through Sparkle. You may disable automatic\n"
    "update checks in the application. Update verification reduces tampering risk but\n"
    "does not create an absolute security guarantee.\n"
    "\n"
    "11. General terms\n"
    "\n"
    "If a provision of these terms is unenforceable, the remaining provisions remain\n"
    "in effect. Failure to enforce a provision is not a waiver. You may not transfer\n"
    "these terms where applicable law prohibits the transfer restriction.\n"
    "\n"
    "12. Contact\n"
    "\n"
    "Questions about these terms may be sent to legal@hippocampus.ai.\n"
    "\n"
    "The engineering codename MCI means Memory Context Interface and refers to the\n"
    "same local Hippocampus software covered by these terms.\n"
};

data 'styl' (5000, "English") {
    $"0001"           /* 1 style run */
    $"00000000"       /* start offset */
    $"000C"           /* height */
    $"000A"           /* ascent */
    $"0000"           /* font ID (system) */
    $"0000"           /* face (plain) */
    $"000A"           /* size 10 */
    $"0000 0000 0000" /* color (black) */
};
