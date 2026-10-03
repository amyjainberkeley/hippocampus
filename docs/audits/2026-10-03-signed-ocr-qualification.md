# October 3 signed OCR runtime qualification

Source under test: `ef765d664977f7bbf35b82d1877429ea364c946e`.

The freshly frozen worker previously exceeded its 30-second deadline on its
first execution. This follow-up uses the production `tools/ocr/bundle.py`
embedding/signing path to create an independent Developer ID-signed copy. The
source/model/runtime manifest is verified before copying, and each native
binary/framework is signed and strictly verified. No installed app is changed.
An independent post-copy check verified all 151 native files against the
production Team ID, all three model hashes and the unchanged worker sources.

On the **first execution of this signed copy**, the real stdin/stdout worker
read all ten synthetic 12-pixel chat lines exactly in 24.029 seconds. A second
synthetic code screenshot returned all eight lines exactly in 4.630 seconds.
Neither contained extra lines or measured character errors. Four blank strips
(3840×1, 1×3840, 3000×20, 20×3000) returned no text in 0.742–0.960 seconds.
Every process used a minimal environment and the original 30-second timeout.

This was the same Mac, which had already executed the preceding runtime.
It was not a fresh-machine, rebooted-cache, downloaded-app or full-app test.
Signing and OS/library cache effects have not been separated experimentally;
the earlier timeout remains a real failed check, not a dismissed outlier.
First-use latency still needs qualification in the complete signed application.
No deadline, assertion, privacy check or model was changed for these results.

The release notes now describe the actual opt-in transcript behavior and new
OCR preview. Previously they incorrectly promised automatic per-session
handoffs and background imports for all desktop users.

The release-contract check initially passed 229 checks and failed one because
it expected an obsolete completion-slide phrase. The current slide explicitly
says local briefs need no model download; the contract now checks that wording,
preserving the same zero-download requirement. All 230 checks pass. No product
behavior or release gate was removed to make the check green.

Private synthetic fixtures, signed runtime and diagnostics are retained outside
the repository. No personal screenshot, memory, provider key or certificate
private key is part of this source checkpoint. The installed owner app,
historical index, permissions and public downloads are unchanged.
