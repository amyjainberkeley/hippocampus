// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The menu-bar app's words for handing context to AI tools (SPEC 5 and 9):
/// the Ask panel's ⌘↩ hint, its notes after it opens a tool, the first-use
/// sheet, and Preferences' Disconnect and Disconnect All. None yet. Every
/// string passes `MenuBarCopyStyleTests`' rules and
/// `scripts/check-launch-copy.sh`.
public enum HandoffCopy {}
