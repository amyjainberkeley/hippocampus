//! Typed views over the MCP protocol's `initialize` / `tools/list` /
//! `tools/call` / `resources/list` / `resources/read` / `prompts/list` /
//! `prompts/get` payloads.
//!
//! The wire shapes are documented at <https://spec.modelcontextprotocol.io/>;
//! these structs deliberately deserialize **leniently** — every field
//! except the ones the V2-MCP-3 aggregator needs is captured into
//! `extra` (a flat JSON object) so servers can ship vendor extensions
//! without breaking us.

use serde::{Deserialize, Serialize};

/// Server identity returned by `initialize`. Mirrors what the MCI
/// producer server sends from `apps/agent/src/mcp/server.rs::handle_initialize`.
#[derive(Debug, Clone, Deserialize)]
pub struct ServerInfo {
    /// Server's self-reported name (e.g. `"hippocampus"`, `"gbrain"`).
    pub name: String,
    /// Server's self-reported version (e.g. `"0.0.1"`).
    pub version: String,
}

/// Capability advertisement from `initialize`. We only model the
/// fields the aggregator routes on (`tools` / `resources` / `prompts`
/// presence). Anything else stays in `extra`.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ServerCapabilities {
    /// `tools` capability object. Presence indicates the server
    /// supports `tools/list` + `tools/call`.
    #[serde(default)]
    pub tools: Option<serde_json::Value>,
    /// `resources` capability object. Presence indicates
    /// `resources/list` + `resources/read`.
    #[serde(default)]
    pub resources: Option<serde_json::Value>,
    /// `prompts` capability object. Presence indicates
    /// `prompts/list` + `prompts/get`.
    #[serde(default)]
    pub prompts: Option<serde_json::Value>,
}

impl ServerCapabilities {
    /// True iff the server advertised the `tools` capability.
    #[must_use]
    pub fn supports_tools(&self) -> bool {
        self.tools.is_some()
    }
    /// True iff the server advertised the `resources` capability.
    #[must_use]
    pub fn supports_resources(&self) -> bool {
        self.resources.is_some()
    }
    /// True iff the server advertised the `prompts` capability.
    #[must_use]
    pub fn supports_prompts(&self) -> bool {
        self.prompts.is_some()
    }
}

/// Result of a successful `initialize` handshake.
#[derive(Debug, Clone, Deserialize)]
pub struct InitializeResult {
    /// MCP calendar-version string the server advertises (e.g.
    /// `"2024-11-05"`). Mismatch with [`crate::MCP_PROTOCOL_VERSION`]
    /// is logged but not fatal — the spec calls negotiation
    /// best-effort.
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    /// Capability bits.
    #[serde(default)]
    pub capabilities: ServerCapabilities,
    /// Server identity.
    #[serde(rename = "serverInfo")]
    pub server_info: ServerInfo,
    /// Optional natural-language guidance the server provides for
    /// downstream agents (Claude Code surfaces this in its UI).
    #[serde(default)]
    pub instructions: Option<String>,
}

/// One tool definition as returned by `tools/list`. The aggregator
/// hashes `name` for the `mcp_polls_count{server_hash}` telemetry per
/// scoping memo §5.4; nothing about the schema is logged.
#[derive(Debug, Clone, Deserialize)]
pub struct ToolDef {
    /// Tool name (e.g. `"mci_recall"`, `"slack_search_messages"`).
    pub name: String,
    /// Optional human-readable description.
    #[serde(default)]
    pub description: Option<String>,
    /// JSON-Schema describing the `arguments` shape of `tools/call`.
    /// Kept as `serde_json::Value` so we do not need a JSON-Schema
    /// crate — the aggregator validates at the call site, not here.
    #[serde(rename = "inputSchema", default)]
    pub input_schema: Option<serde_json::Value>,
}

/// One resource definition as returned by `resources/list`.
#[derive(Debug, Clone, Deserialize)]
pub struct ResourceDef {
    /// URI scheme the resource lives under (e.g. `"file://"`,
    /// `"slack://"`).
    pub uri: String,
    /// Optional human-readable name.
    #[serde(default)]
    pub name: Option<String>,
    /// Optional human-readable description.
    #[serde(default)]
    pub description: Option<String>,
    /// Optional MIME type the resource yields.
    #[serde(rename = "mimeType", default)]
    pub mime_type: Option<String>,
}

/// One prompt definition as returned by `prompts/list`. v1 V2-MCP
/// scope ignores prompts (memo §8.4) — we surface them but no caller
/// of this crate uses them yet.
#[derive(Debug, Clone, Deserialize)]
pub struct PromptDef {
    /// Prompt name (e.g. `"summarize_thread"`).
    pub name: String,
    /// Optional human-readable description.
    #[serde(default)]
    pub description: Option<String>,
    /// Optional arguments list.
    #[serde(default)]
    pub arguments: Option<serde_json::Value>,
}

/// Result of a successful `tools/call`. The MCP spec defines
/// `content` as a heterogeneous array (text / image / resource); we
/// expose it as raw `serde_json::Value` plus a convenience
/// [`Self::text_content`] accessor for the most common case.
#[derive(Debug, Clone, Deserialize)]
pub struct ToolResult {
    /// Heterogeneous content array per the MCP spec.
    #[serde(default)]
    pub content: Vec<serde_json::Value>,
    /// `isError: true` indicates the tool ran but logically failed
    /// (e.g. "no results"). Distinct from a JSON-RPC error — the
    /// transport call still succeeded.
    #[serde(rename = "isError", default)]
    pub is_error: bool,
}

impl ToolResult {
    /// Convenience accessor for the most common content shape: a
    /// single `{"type":"text","text":"..."}` entry. Returns the
    /// concatenation of every text entry in order — empty string if
    /// none.
    #[must_use]
    pub fn text_content(&self) -> String {
        let mut out = String::new();
        for item in &self.content {
            if item.get("type").and_then(|v| v.as_str()) == Some("text") {
                if let Some(t) = item.get("text").and_then(|v| v.as_str()) {
                    if !out.is_empty() {
                        out.push('\n');
                    }
                    out.push_str(t);
                }
            }
        }
        out
    }
}

/// One content entry from `resources/read`. The spec also defines a
/// `blob` variant (base64) — we surface it as raw JSON since v1 has
/// no consumer.
#[derive(Debug, Clone, Deserialize)]
pub struct ResourceContent {
    /// URI of the resource read.
    pub uri: String,
    /// Optional MIME type.
    #[serde(rename = "mimeType", default)]
    pub mime_type: Option<String>,
    /// Text payload if the resource is text.
    #[serde(default)]
    pub text: Option<String>,
    /// Base64-encoded blob payload if the resource is binary.
    #[serde(default)]
    pub blob: Option<String>,
}

/// Result of `resources/read` — one or more content entries.
#[derive(Debug, Clone, Deserialize)]
pub struct ReadResourceResult {
    /// One entry per concrete content the resource yields.
    pub contents: Vec<ResourceContent>,
}

/// One message from a `prompts/get` result. Kept opaque (raw JSON)
/// since v1 has no prompt consumer; see memo §8.4.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PromptMessage(pub serde_json::Value);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initialize_result_parses_with_optional_fields_omitted() {
        let raw = r#"{
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "gbrain", "version": "0.0.0"}
        }"#;
        let parsed: InitializeResult = serde_json::from_str(raw).expect("parse");
        assert_eq!(parsed.protocol_version, "2024-11-05");
        assert_eq!(parsed.server_info.name, "gbrain");
        assert!(parsed.capabilities.supports_tools());
        assert!(!parsed.capabilities.supports_resources());
        assert!(parsed.instructions.is_none());
    }

    #[test]
    fn tool_def_parses_with_input_schema_absent() {
        let raw = r#"{"name": "ping"}"#;
        let parsed: ToolDef = serde_json::from_str(raw).expect("parse");
        assert_eq!(parsed.name, "ping");
        assert!(parsed.description.is_none());
        assert!(parsed.input_schema.is_none());
    }

    #[test]
    fn tool_result_text_content_joins_text_entries() {
        let raw = r#"{
            "content": [
                {"type":"text","text":"first"},
                {"type":"image","data":"…"},
                {"type":"text","text":"second"}
            ],
            "isError": false
        }"#;
        let parsed: ToolResult = serde_json::from_str(raw).expect("parse");
        assert_eq!(parsed.text_content(), "first\nsecond");
        assert!(!parsed.is_error);
    }

    #[test]
    fn tool_result_empty_content_yields_empty_string() {
        let raw = r#"{"content":[],"isError":false}"#;
        let parsed: ToolResult = serde_json::from_str(raw).expect("parse");
        assert_eq!(parsed.text_content(), "");
    }

    #[test]
    fn resource_content_parses_text_and_blob_variants() {
        let text_raw = r#"{"uri":"file:///a.txt","text":"hello","mimeType":"text/plain"}"#;
        let text: ResourceContent = serde_json::from_str(text_raw).expect("parse");
        assert_eq!(text.text.as_deref(), Some("hello"));
        assert!(text.blob.is_none());

        let blob_raw = r#"{"uri":"file:///a.png","blob":"aGVsbG8=","mimeType":"image/png"}"#;
        let blob: ResourceContent = serde_json::from_str(blob_raw).expect("parse");
        assert!(blob.text.is_none());
        assert_eq!(blob.blob.as_deref(), Some("aGVsbG8="));
    }
}
