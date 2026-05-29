//! Test-fixture MCP server. **Not shipped.**
//!
//! Built under the `test-fixtures` Cargo feature (dev-only) so the
//! integration tests can spawn a real subprocess and exercise
//! [`mci_mcp_client::StdioTransport`] against it. The wire shape
//! mirrors the production MCP framing at
//! `apps/agent/src/mcp/jsonrpc.rs` + `server.rs` so byte-compatibility
//! with the CEO's gbrain (the §2.2 immediate test target) is
//! covered by the same code path.
//!
//! Supported methods:
//! - `initialize` — returns canned `serverInfo` + `tools` capability.
//! - `tools/list` — returns `echo` + `slow_echo` + `error_echo`.
//! - `tools/call` —
//!     - `echo({msg})` → `{content: [{type:"text", text: msg}]}`
//!     - `slow_echo({msg, delay_ms})` → same but sleeps first
//!     - `error_echo({code, message})` → JSON-RPC error
//! - `resources/list` — returns one resource `mci-fixture://hello`.
//! - `resources/read({uri})` — returns canned text for that URI.
//! - `prompts/list` — empty list.
//! - `ping` — `{}`.
//! - Any notification (`id` absent) — silently consumed.
//! - Anything else — `METHOD_NOT_FOUND`.
//!
//! Operational logs go to stderr (silently drained by the transport).
//!
//! # Special control commands (test affordances)
//!
//! Passing `--exit-on-init` makes the fixture exit(0) immediately
//! after responding to `initialize`. Used by the "server crash
//! mid-call" test.

// Test-fixture binary — pedantic style nits below are deliberate
// (single-function main, by-value `serde_json::Value` payloads).
#![allow(
    clippy::too_many_lines,
    clippy::match_same_arms,
    clippy::redundant_closure_for_method_calls,
    clippy::needless_pass_by_value
)]

use std::io::{BufRead, BufReader, Write};
use std::time::Duration;

use serde_json::{json, Value};

fn main() {
    let exit_on_init = std::env::args().any(|a| a == "--exit-on-init");
    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let mut reader = BufReader::new(stdin.lock());
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return, // EOF
            Ok(_) => {}
            Err(_) => return,
        }
        if line.trim().is_empty() {
            continue;
        }
        let Ok(req): Result<Value, _> = serde_json::from_str(&line) else {
            // Drop malformed frames silently — matches the real
            // server behavior at apps/agent/src/mcp/server.rs.
            continue;
        };
        let id = req.get("id").cloned();
        let method = req.get("method").and_then(|v| v.as_str()).unwrap_or("");
        let params = req.get("params").cloned();

        // Notifications: no id → silent.
        if id.is_none() {
            continue;
        }
        let id = id.unwrap();

        let resp = match method {
            "initialize" => ok(
                &id,
                json!({
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": {},
                        "resources": {},
                        "prompts": {}
                    },
                    "serverInfo": {
                        "name": "mci-mcp-echo-fixture",
                        "version": "0.0.1"
                    }
                }),
            ),
            "tools/list" => ok(
                &id,
                json!({
                    "tools": [
                        {
                            "name": "echo",
                            "description": "echoes msg back as text content",
                            "inputSchema": {
                                "type": "object",
                                "properties": {"msg": {"type": "string"}},
                                "required": ["msg"]
                            }
                        },
                        {
                            "name": "slow_echo",
                            "description": "echo with an artificial delay (for timeout tests)",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "msg": {"type": "string"},
                                    "delay_ms": {"type": "integer"}
                                }
                            }
                        },
                        {
                            "name": "error_echo",
                            "description": "always returns a JSON-RPC error",
                            "inputSchema": {
                                "type": "object",
                                "properties": {
                                    "code": {"type": "integer"},
                                    "message": {"type": "string"}
                                }
                            }
                        }
                    ]
                }),
            ),
            "tools/call" => handle_tools_call(&id, params),
            "resources/list" => ok(
                &id,
                json!({
                    "resources": [{
                        "uri": "mci-fixture://hello",
                        "name": "hello",
                        "mimeType": "text/plain"
                    }]
                }),
            ),
            "resources/read" => {
                let uri = params
                    .as_ref()
                    .and_then(|p| p.get("uri"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if uri == "mci-fixture://hello" {
                    ok(
                        &id,
                        json!({
                            "contents": [{
                                "uri": uri,
                                "mimeType": "text/plain",
                                "text": "hello from fixture"
                            }]
                        }),
                    )
                } else {
                    err(&id, -32602, "unknown uri")
                }
            }
            "prompts/list" => ok(&id, json!({"prompts": []})),
            "ping" => ok(&id, json!({})),
            other => err(&id, -32601, &format!("unknown method: {other}")),
        };

        let line = serde_json::to_string(&resp).unwrap_or_else(|_| "{}".to_owned());
        let _ = writeln!(out, "{line}");
        let _ = out.flush();

        if exit_on_init && method == "initialize" {
            std::process::exit(0);
        }
    }
}

fn handle_tools_call(id: &Value, params: Option<Value>) -> Value {
    let Some(params) = params else {
        return err(id, -32602, "tools/call needs params");
    };
    let name = params.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    match name {
        "echo" => {
            let msg = args.get("msg").and_then(|v| v.as_str()).unwrap_or("");
            ok(
                id,
                json!({
                    "content": [{"type":"text","text": msg}],
                    "isError": false
                }),
            )
        }
        "slow_echo" => {
            let msg = args.get("msg").and_then(|v| v.as_str()).unwrap_or("");
            let delay_ms = args
                .get("delay_ms")
                .and_then(|v| v.as_u64())
                .unwrap_or(0);
            if delay_ms > 0 {
                std::thread::sleep(Duration::from_millis(delay_ms));
            }
            ok(
                id,
                json!({
                    "content": [{"type":"text","text": msg}],
                    "isError": false
                }),
            )
        }
        "error_echo" => {
            let code = args.get("code").and_then(|v| v.as_i64()).unwrap_or(-32000);
            let msg = args
                .get("message")
                .and_then(|v| v.as_str())
                .unwrap_or("error_echo");
            err(id, code, msg)
        }
        other => err(id, -32601, &format!("unknown tool: {other}")),
    }
}

fn ok(id: &Value, result: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
}

fn err(id: &Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {"code": code, "message": message}
    })
}
