//! `LlamaBackend` trait — pluggable text generation backend for brief
//! authoring.
//!
//! Production: `LlamaCoreMLBackend` in `adapters/macos/mci-llama-coreml/`.
//! Tests + dev: [`StubLlamaBackend`] returns canned output shaped like
//! real Llama output (with `[event:N]` citation markers).

use thiserror::Error;

/// Errors from [`LlamaBackend::generate`].
#[derive(Debug, Error)]
pub enum GenerateError {
    /// The prompt was empty or otherwise invalid.
    #[error("generate: invalid prompt: {0}")]
    InvalidPrompt(String),
    /// The generation backend failed.
    #[error("generate: backend: {0}")]
    Backend(String),
}

/// Pluggable text generation backend.
///
/// Implementations take a fully-rendered prompt string and return the
/// model's raw text output. The caller (`LlamaBriefAuthor`) handles
/// prompt construction and output parsing — the backend is purely
/// "text in, text out."
pub trait LlamaBackend: Send + Sync + std::fmt::Debug {
    /// Generate text from the given prompt.
    ///
    /// Returns the raw model output. The caller parses structure
    /// (title, body, citations) from the output.
    fn generate(&self, prompt: &str) -> Result<String, GenerateError>;

    /// Maximum output tokens this backend supports.
    fn max_output_tokens(&self) -> usize;
}

/// Stub backend that returns canned output shaped like real Llama output.
///
/// The output includes `[event:N]` citation markers matching the event IDs
/// passed via [`StubLlamaBackend::with_event_ids`], so the full
/// prompt→generate→parse→cite pipeline exercises in tests.
#[derive(Debug, Clone)]
pub struct StubLlamaBackend {
    event_ids: Vec<u64>,
}

impl StubLlamaBackend {
    /// Create a stub that generates output citing the given event IDs.
    #[must_use]
    pub fn with_event_ids(event_ids: Vec<u64>) -> Self {
        Self { event_ids }
    }
}

impl Default for StubLlamaBackend {
    fn default() -> Self {
        Self {
            event_ids: vec![1, 2, 3],
        }
    }
}

impl LlamaBackend for StubLlamaBackend {
    fn generate(&self, _prompt: &str) -> Result<String, GenerateError> {
        let mut body_lines = Vec::new();
        for &id in &self.event_ids {
            body_lines.push(format!(
                "- Worked on task related to event {id} [event:{id}]"
            ));
        }
        let body = body_lines.join("\n");

        let citation_list: Vec<String> = self
            .event_ids
            .iter()
            .map(|id| format!("[event:{id}]"))
            .collect();

        Ok(format!(
            "Daily Work Summary\n\n{body}\n\n###CITATIONS:\n{}",
            citation_list.join(", ")
        ))
    }

    fn max_output_tokens(&self) -> usize {
        256
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_backend_produces_citation_markers() {
        let backend = StubLlamaBackend::with_event_ids(vec![10, 20]);
        let output = backend.generate("test prompt").unwrap();
        assert!(output.contains("[event:10]"));
        assert!(output.contains("[event:20]"));
        assert!(output.contains("###CITATIONS:"));
    }

    #[test]
    fn stub_backend_default_cites_1_2_3() {
        let backend = StubLlamaBackend::default();
        let output = backend.generate("test").unwrap();
        assert!(output.contains("[event:1]"));
        assert!(output.contains("[event:2]"));
        assert!(output.contains("[event:3]"));
    }
}
