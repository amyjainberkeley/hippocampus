//! A reading's text as typed blocks (SPEC 4.2): what was read, in order, as
//! headings, paragraphs, lists, code, terminal output, tables, chat turns,
//! quotes and mail's header lines.
//!
//! Nothing is invented: every block holds only text that was read, and a
//! block's kind changes only how it is drawn. Blocks are made when a reading
//! is shown, from the stored or the live `main`, so a change to the rules
//! needs no re-clean. The window gets them with the FFI's reading of a
//! moment, and an AI tool gets [`markdown`] of them.
//!
//! A seam for now: a reading is one paragraph holding all of `main`, so the
//! window draws what it drew before. The rules by kind of window and the
//! other kinds of block land with formatted transcripts.

use serde::{Deserialize, Serialize};

use crate::EventSource;

/// The window a reading came from, as the rules by kind of window read it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Window<'a> {
    /// The app's bundle id.
    pub app: Option<&'a str>,
    /// The window's title.
    pub title: Option<&'a str>,
    /// The page's address, when known.
    pub url: Option<&'a str>,
}

/// One block of a reading, in the order it was read. Serialized with its
/// kind as `"kind"`: `{"kind": "paragraph", "text": "…"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Block {
    /// Prose.
    Paragraph {
        /// The text, as read.
        text: String,
    },
}

impl Block {
    /// The text the block holds, as read.
    #[must_use]
    pub fn text(&self) -> &str {
        match self {
            Self::Paragraph { text } => text,
        }
    }
}

/// The blocks of `main`, the text a person was reading in `window`, which
/// was acquired as `source`: one paragraph holding all of it, or none when
/// it holds no text.
#[must_use]
pub fn blocks(main: &str, window: &Window<'_>, source: EventSource) -> Vec<Block> {
    let _ = (window, source);
    if main.trim().is_empty() {
        return Vec::new();
    }
    vec![Block::Paragraph {
        text: main.to_owned(),
    }]
}

/// The blocks as Markdown, for an AI tool (SPEC 4.7): one after another,
/// with a blank line between them.
#[must_use]
pub fn markdown(blocks: &[Block]) -> String {
    blocks
        .iter()
        .map(Block::text)
        .collect::<Vec<_>>()
        .join("\n\n")
}
