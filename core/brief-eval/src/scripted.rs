//! Scripted [`LlamaBackend`] — returns a canned response.
//!
//! The default CI backend. Reads `fixtures/scripted/<name>.md` once
//! and returns it from `generate()` regardless of the prompt. Lets the
//! eval framework prove the scorer + lifecycle wire up end-to-end
//! without invoking any model.
//!
//! Different from [`mci_brief::llama_backend::StubLlamaBackend`]: the
//! stub produces generic "Worked on task related to event N" text
//! that has no factual content (and is therefore SUPPOSED to fail
//! the eval — that's the "you must download the real model" signal).
//! The scripted backend returns hand-shaped output that matches what
//! a passing model would emit.

use mci_brief::llama_backend::{GenerateError, LlamaBackend};

/// Backend that returns a fixed string for every `generate()` call.
#[derive(Debug, Clone)]
pub struct ScriptedLlamaBackend {
    response: String,
    max_output_tokens: usize,
}

impl ScriptedLlamaBackend {
    /// Build a scripted backend that replays `response` verbatim.
    #[must_use]
    pub fn new(response: impl Into<String>) -> Self {
        Self {
            response: response.into(),
            max_output_tokens: 1024,
        }
    }

    /// Override the reported `max_output_tokens` (default: 1024).
    #[must_use]
    pub fn with_max_output_tokens(mut self, n: usize) -> Self {
        self.max_output_tokens = n;
        self
    }
}

impl LlamaBackend for ScriptedLlamaBackend {
    fn generate(&self, _prompt: &str) -> Result<String, GenerateError> {
        Ok(self.response.clone())
    }

    fn max_output_tokens(&self) -> usize {
        self.max_output_tokens
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scripted_backend_returns_canned_response() {
        let backend = ScriptedLlamaBackend::new("Title\n\n- bullet [event:1]");
        let out = backend.generate("any prompt").unwrap();
        assert!(out.contains("[event:1]"));
        assert_eq!(backend.max_output_tokens(), 1024);
    }
}
