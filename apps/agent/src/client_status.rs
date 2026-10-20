//! `mci-agent clients --json`: the AI tools Hippocampus works with and what
//! each has of it, for the window's AI Tools page (SPEC 3.8): whether its
//! look-up entry and session-start hook are there, and the step it needs, if
//! any. Content-free: it says nothing of the memory and never opens it, so
//! it needs no key.
//!
//! A seam for now: it names the two tools Hippocampus connects today,
//! Claude Code and Codex, and reads nothing about them. Their status from
//! each tool's own settings lands with the AI Tools page.

use serde::Serialize;

use crate::understanding::ReadError;

/// The tools, in the order AI Tools lists them.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Clients {
    /// One entry per tool.
    pub tools: Vec<ClientTool>,
}

/// One AI tool.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ClientTool {
    /// Its stable id: `claude-code` or `codex`.
    pub id: String,
    /// Its name, as the tool writes it.
    pub name: String,
}

/// The tools Hippocampus connects today.
#[must_use]
pub fn clients() -> Clients {
    Clients {
        tools: [("claude-code", "Claude Code"), ("codex", "Codex")]
            .into_iter()
            .map(|(id, name)| ClientTool {
                id: id.into(),
                name: name.into(),
            })
            .collect(),
    }
}

/// `mci-agent clients`: the tools as JSON. `args` are the command's own
/// flags, after the shared ones; it has none yet.
///
/// # Errors
/// [`ReadError::Failed`] only if the answer can't be written.
pub fn run_cli(args: &[String]) -> Result<serde_json::Value, ReadError> {
    let _ = args;
    serde_json::to_value(clients())
        .map_err(|_| ReadError::Failed("clients could not be written".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn today_it_is_claude_code_and_codex() {
        let ids: Vec<String> = clients().tools.into_iter().map(|tool| tool.id).collect();
        assert_eq!(ids, ["claude-code", "codex"]);
        let value = run_cli(&[]).unwrap();
        assert_eq!(value["tools"][1]["name"], "Codex");
    }
}
