# Screenshot provenance

Every PNG in this directory is intentionally classified so product captures
are never confused with illustrative marketing art.

| Asset | Classification | Provenance |
| --- | --- | --- |
| `hero-onboarding-welcome.png` | Exact product capture | Current `onboarding` SwiftUI executable at the Welcome step. Captured with macOS dark appearance requested to verify the V1 light-window authority. Contains no runtime data. |
| `hero-onboarding-trust-panel.png` | Exact product capture | Current `onboarding` SwiftUI executable at the Trust step. Captured with macOS dark appearance requested to verify the V1 light-window authority. Contains no runtime data. |
| `hero-recall-ui.png` | Exact product capture with synthetic data | Current `recall-ui` SwiftUI executable on the Now surface. It reads a disposable, locally seeded SQLCipher brain containing 20 synthetic work events and one synthetic daily brief. No personal data is present. |
| `hero-cli.png` | Illustrative render | Programmatic terminal render produced by `scripts/render-cli-screenshot.py` from the committed synthetic benchmark scorecard. It is not a live terminal screenshot and does not read a personal brain. |

`hero-hippocampus-menu.png` was retired because it did not show the current
menu-bar product and carried the old tilted artwork. Do not recreate that
filename with onboarding or another substitute. A future menu screenshot must
be an exact capture of the open native menu and documented here before use.
