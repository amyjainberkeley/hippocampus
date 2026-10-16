//! Tool definitions — names + MCP `tools/list` schemas.
//!
//! Every tool is **read-only** (CSO veto-gate on any addition that mutates):
//! `recall`, `events_since`, `stats`, `episodes`, `events_by_app`, `context`,
//! `day`, `searches`, `person_model` and `sessions`, and in the command bar's
//! assistant session `ask` and `suggest`.
//!
//! Names carry no prefix: clients already add the server's, so Claude Code
//! shows `mcp__hippocampus__recall`. The names these tools had before 0.3
//! (`mci_recall`, …, `mci_user_model`) still work as hidden aliases, so a
//! client's saved allow rules and older callers keep working, but
//! `tools/list` never offers them.
//!
//! The dispatcher in `super::server` routes only names [`ToolName::from_wire`]
//! knows; an unknown name returns `METHOD_NOT_FOUND`, never falls through to
//! a write surface.

use std::fmt;

/// The tools. Used by the dispatcher to route `tools/call` and by
/// `tool_definitions` to assemble the `tools/list` response.
///
/// **Structural read-only invariant** — adding a variant here is the
/// only way a new tool reaches the wire. Any mutating tool MUST land
/// behind a separate CSO-signed PR (per ADR-0017 §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolName {
    /// `recall` — lexical (eventually hybrid) recall.
    Recall,
    /// `events_since` — timeline cursor.
    EventsSince,
    /// `stats` — content-free aggregate.
    Stats,
    /// `episodes` — recent episodes with event counts.
    Episodes,
    /// `events_by_app` — events filtered by exact app bundle id.
    EventsByApp,
    /// `context` — bounded, cited context for local agent handoff.
    Context,
    /// `day` — a day's measured breakdown and written account.
    Day,
    /// `searches` — searches read from captured pages.
    Searches,
    /// `person_model` — what Hippocampus has learned about the user.
    UserModel,
    /// `sessions` — a day's work sessions, surface and beneath.
    Sessions,
    /// `ask` — answer from memory (assistant sessions only).
    Ask,
    /// `suggest` — suggestions for now (assistant sessions only).
    Suggest,
}

impl ToolName {
    /// Every tool, in the order `tools/list` and the assistant list them.
    pub const ALL: [Self; 12] = [
        Self::Recall,
        Self::EventsSince,
        Self::Stats,
        Self::Episodes,
        Self::EventsByApp,
        Self::Context,
        Self::Day,
        Self::Searches,
        Self::UserModel,
        Self::Sessions,
        Self::Ask,
        Self::Suggest,
    ];

    /// Wire name (the string an MCP client passes in `tools/call`).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Recall => "recall",
            Self::EventsSince => "events_since",
            Self::Stats => "stats",
            Self::Episodes => "episodes",
            Self::EventsByApp => "events_by_app",
            Self::Context => "context",
            Self::Day => "day",
            Self::Searches => "searches",
            Self::UserModel => "person_model",
            Self::Sessions => "sessions",
            Self::Ask => "ask",
            Self::Suggest => "suggest",
        }
    }

    /// The name the tool had before 0.3, still accepted and never listed.
    #[must_use]
    pub const fn hidden_alias(self) -> &'static str {
        match self {
            Self::Recall => "mci_recall",
            Self::EventsSince => "mci_events_since",
            Self::Stats => "mci_stats",
            Self::Episodes => "mci_episodes",
            Self::EventsByApp => "mci_events_by_app",
            Self::Context => "mci_context",
            Self::Day => "mci_day",
            Self::Searches => "mci_searches",
            Self::UserModel => "mci_user_model",
            Self::Sessions => "mci_sessions",
            Self::Ask => "mci_ask",
            Self::Suggest => "mci_suggest",
        }
    }

    /// Parse the wire name, or a hidden alias. Unknown names return `None`
    /// so the dispatcher can emit `METHOD_NOT_FOUND` without panicking.
    #[must_use]
    pub fn from_wire(s: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|tool| tool.as_str() == s || tool.hidden_alias() == s)
    }
}

impl fmt::Display for ToolName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Build the `tools` array the MCP `tools/list` response carries.
///
/// Each entry is the canonical MCP tool descriptor:
/// `{ "name", "description", "inputSchema" }`. We keep the schemas
/// hand-written here (no `schemars` dep) — they're small and stable.
#[must_use]
#[allow(clippy::too_many_lines)]
pub fn tool_definitions() -> serde_json::Value {
    serde_json::json!([
        {
            "name": ToolName::Recall.as_str(),
            "description": "Search your local work memory. Hippocampus records permitted \
                             app, window, browser-tab, and page context after you opt in, \
                             and keeps it encrypted on this Mac. \
                             Use this tool to recall anything you've seen or done. Query \
                             with natural language: 'that article about Rust I read \
                             yesterday', 'what was I working on this morning', 'the URL \
                             with pricing info'. `hits` are ranked best first. When \
                             `outcome` is 'degraded', the hits are ranked but not \
                             independently verified; `degradation` says what was \
                             unavailable.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Natural-language search query."
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum hits to return. Defaults to 10.",
                        "minimum": 1,
                        "maximum": 100
                    }
                },
                "required": ["query"]
            }
        },
        {
            "name": ToolName::EventsSince.as_str(),
            "description": "Get recent screen activity after a timestamp. Each event \
                             includes the app, window title, URL (if browser), and \
                             captured text. Use for 'what happened in the last hour' \
                             or incremental polling.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ts_us": {
                        "type": "integer",
                        "description": "Microseconds since UNIX epoch. Events strictly after this timestamp are returned.",
                        "minimum": 0
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum events to return. Defaults to 100.",
                        "minimum": 1,
                        "maximum": 1000
                    }
                },
                "required": ["ts_us"]
            }
        },
        {
            "name": ToolName::Stats.as_str(),
            "description": "Quick overview of your screen memory: total events captured, \
                             time range covered. No content returned — just counts. Use \
                             to check if Hippocampus is running and how much memory is \
                             available.",
            "inputSchema": {
                "type": "object",
                "properties": {}
            }
        },
        {
            "name": ToolName::Episodes.as_str(),
            "description": "List recent work sessions. A session is one stretch of work \
                             in one app (e.g. '45 min in VS Code', '20 min \
                             browsing docs'). Use for 'what did I work on today' at a \
                             glance.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "limit": {
                        "type": "integer",
                        "description": "Maximum episodes to return. Defaults to 20.",
                        "minimum": 1,
                        "maximum": 100
                    }
                }
            }
        },
        {
            "name": ToolName::EventsByApp.as_str(),
            "description": "Get screen activity for a specific app (by bundle ID like \
                             'com.apple.Safari'). Use for 'what sites did I visit' or \
                             'what files did I edit in Xcode'.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "app_bundle_id": {
                        "type": "string",
                        "description": "Exact app bundle identifier (e.g. 'com.apple.Safari', 'com.microsoft.VSCode')."
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum events to return. Defaults to 50.",
                        "minimum": 1,
                        "maximum": 1000
                    }
                },
                "required": ["app_bundle_id"]
            }
        },
        {
            "name": ToolName::Context.as_str(),
            "description": "Get context for the current task: where things stand, what \
                             changed, decisions and what is still open, each with its source. \
                             Sections with nothing solid are left out.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "focus": {
                        "type": "string",
                        "description": "Optional project, task, or question used to focus candidate retrieval."
                    },
                    "project": {
                        "type": "string",
                        "description": "Compatibility alias for focus when the caller has a project name."
                    },
                    "max_tokens": {
                        "type": "integer",
                        "description": "Maximum content-token estimate. Defaults to 1200.",
                        "minimum": 128,
                        "maximum": 4096
                    },
                    "max_evidence": {
                        "type": "integer",
                        "description": "Maximum distinct event citations. Defaults to 24.",
                        "minimum": 1,
                        "maximum": 64
                    }
                }
            }
        },
        {
            "name": ToolName::Day.as_str(),
            "description": "How a day on the computer went: measured active time by hour, app and kind \
                             of work, focus blocks, app switching, searches, the day's work sessions, \
                             and a written account. Use for 'what did I do today', 'where did my time \
                             go', or a daily summary.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "date": { "type": "string", "description": "Local date YYYY-MM-DD. Defaults to today." }
                }
            }
        },
        {
            "name": ToolName::Searches.as_str(),
            "description": "What the user searched for (Google, YouTube, GitHub, Stack Overflow, \
                             Wikipedia, Amazon and more), newest first, read from captured pages.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "hours": { "type": "integer", "description": "Hours back. Defaults to 24.", "minimum": 1, "maximum": 744 },
                    "limit": { "type": "integer", "description": "Maximum searches. Defaults to 50.", "minimum": 1, "maximum": 500 }
                }
            }
        },
        {
            "name": ToolName::UserModel.as_str(),
            "description": "What Hippocampus has learned about the user, with sources.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Optional topic to focus on." },
                    "limit": { "type": "integer", "description": "Maximum propositions. Defaults to 20.", "minimum": 1, "maximum": 200 }
                }
            }
        },
        {
            "name": ToolName::Sessions.as_str(),
            "description": "A day's work sessions: for each, what was on screen (the surface) and \
                             what lay beneath it (what you were trying to do), with the \
                             windows and searches involved.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "date": { "type": "string", "description": "Local date YYYY-MM-DD. Defaults to today." }
                }
            }
        }
    ])
}

/// Tools offered only by an assistant session (`mcp-serve --assist`), which
/// the command bar starts. They read the brain and run the on-device model.
#[must_use]
pub fn assistant_tool_definitions() -> serde_json::Value {
    serde_json::json!([
        {
            "name": ToolName::Ask.as_str(),
            "description": "Answer a question from what is on the user's screen now and their own memories with the on-device model, citing them.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "question": { "type": "string" },
                    "now": { "type": "string", "description": "The frontmost app's name, used when its window has no capture." },
                    "app": { "type": "string", "description": "Bundle id of the frontmost app; its latest captured window is source 1." },
                    "title": { "type": "string", "description": "That window's title." }
                },
                "required": ["question"]
            }
        },
        {
            "name": ToolName::Suggest.as_str(),
            "description": "What the user likely wants right now: resume, recent searches, related memories, their day.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "app": { "type": "string" },
                    "title": { "type": "string" },
                    "model": { "type": "boolean", "description": "Add on-device predictions (slower)." }
                }
            }
        }
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listed(definitions: &serde_json::Value) -> Vec<String> {
        definitions
            .as_array()
            .expect("tools is an array")
            .iter()
            .map(|t| t["name"].as_str().unwrap_or("").to_owned())
            .collect()
    }

    #[test]
    fn round_trip_tool_names() {
        for t in ToolName::ALL {
            assert_eq!(ToolName::from_wire(t.as_str()), Some(t));
            assert_eq!(t.to_string(), t.as_str());
        }
    }

    #[test]
    fn the_names_before_0_3_still_work_but_are_never_listed() {
        let offered: Vec<String> = [tool_definitions(), assistant_tool_definitions()]
            .iter()
            .flat_map(listed)
            .collect();
        for t in ToolName::ALL {
            assert_eq!(ToolName::from_wire(t.hidden_alias()), Some(t));
            assert_eq!(
                t.hidden_alias(),
                format!(
                    "mci_{}",
                    if t == ToolName::UserModel {
                        "user_model"
                    } else {
                        t.as_str()
                    }
                )
            );
            assert!(!offered.contains(&t.hidden_alias().to_owned()));
        }
        assert!(
            offered.iter().all(|name| !name.starts_with("mci_")),
            "{offered:?}"
        );
        assert_eq!(
            ToolName::from_wire("mci_user_model"),
            Some(ToolName::UserModel)
        );
        assert_eq!(
            ToolName::from_wire("person_model"),
            Some(ToolName::UserModel)
        );
        assert_eq!(
            ToolName::from_wire("user_model"),
            None,
            "only the two names"
        );
    }

    #[test]
    fn unknown_tool_name_returns_none() {
        assert!(ToolName::from_wire("mci_put_event").is_none());
        assert!(ToolName::from_wire("put_event").is_none());
        assert!(ToolName::from_wire("mci_delete").is_none());
        assert!(ToolName::from_wire("").is_none());
    }

    #[test]
    fn tools_list_offers_the_ten_read_tools_and_the_assistant_two_more() {
        assert_eq!(
            listed(&tool_definitions()),
            [
                "recall",
                "events_since",
                "stats",
                "episodes",
                "events_by_app",
                "context",
                "day",
                "searches",
                "person_model",
                "sessions"
            ]
        );
        assert_eq!(listed(&assistant_tool_definitions()), ["ask", "suggest"]);
    }

    #[test]
    fn the_person_model_says_what_it_is() {
        let definitions = tool_definitions();
        let model = definitions
            .as_array()
            .expect("array")
            .iter()
            .find(|tool| tool["name"] == "person_model")
            .expect("person_model");
        assert_eq!(
            model["description"],
            "What Hippocampus has learned about the user, with sources."
        );
    }

    #[test]
    fn tool_definitions_carry_input_schemas() {
        let defs = tool_definitions();
        for tool in defs.as_array().expect("array") {
            assert!(tool.get("description").is_some(), "missing description");
            assert!(tool.get("inputSchema").is_some(), "missing inputSchema");
        }
    }

    #[test]
    fn recall_description_is_explicitly_opt_in() {
        let definitions = tool_definitions();
        let recall = definitions
            .as_array()
            .expect("array")
            .iter()
            .find(|tool| tool.get("name").and_then(|name| name.as_str()) == Some("recall"))
            .expect("recall definition");
        let description = recall
            .get("description")
            .and_then(|value| value.as_str())
            .expect("recall description");

        assert!(description.contains("after you opt in"));
        assert!(!description.contains("continuously captures"));
    }
}
