# Screenshot provenance

Every PNG in this directory is intentionally classified so product captures
are never confused with illustrative marketing art.

| Asset | Classification | Provenance |
| --- | --- | --- |
| `hero-onboarding-welcome.png` | Exact product capture | Current `onboarding` SwiftUI executable at the Welcome step. Captured with macOS dark appearance requested to verify the V1 light-window authority. Contains no runtime data. |
| `hero-onboarding-trust-panel.png` | Exact product capture | Current `onboarding` SwiftUI executable at the Trust step. Captured with macOS dark appearance requested to verify the V1 light-window authority. Contains no runtime data. |
| `hero-recall-ui.png` | Product render with made-up data | The current `recall-ui` views on the Ask place, drawn off screen by the window's own debug renderer (`recall-ui --synthetic-preview --render-window=<dir>`) from its built-in fixtures: a question answered with its sources, and the moment it came from read as the window showed it. Nothing is read from a memory on this Mac. Window materials are drawn as solid fills. |
| `hero-cli.png` | Illustrative render | Programmatic terminal render produced by `scripts/render-cli-screenshot.py` from the committed synthetic benchmark scorecard. It is not a live terminal screenshot and does not read a personal brain. |

`hero-hippocampus-menu.png` was retired because it did not show the current
menu-bar product and carried the old tilted artwork. Do not recreate that
filename with onboarding or another substitute. A future menu screenshot must
be an exact capture of the open native menu and documented here before use.
