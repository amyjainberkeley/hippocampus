//! Acquisition provenance, independent of retrieval method and application identity.

/// Source asserted by the producer at insertion. Legacy rows remain unknown.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum EventSource {
    /// No acquisition provenance was recorded.
    #[default]
    Unknown,
    /// Text recognized from screen pixels.
    ScreenOcr,
    /// Browser extension page content.
    BrowserPage,
    /// Browser content merged with a visible screen OCR excerpt.
    BrowserPageWithOcr,
    /// Conversation text imported from a transcript file.
    TranscriptImport,
    /// A native application reader, such as Mail or Messages.
    StructuredApp,
    /// Catalog or content acquired from an MCP server.
    McpResource,
}

impl EventSource {
    /// Stable acquisition labels shared by context, MCP and FFI JSON.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::ScreenOcr => "screen_ocr",
            Self::BrowserPage => "browser_page",
            Self::BrowserPageWithOcr => "browser_page_with_ocr",
            Self::TranscriptImport => "transcript_import",
            Self::StructuredApp => "structured_app",
            Self::McpResource => "mcp_resource",
        }
    }

    pub(crate) fn from_stored(value: &str) -> Self {
        match value {
            "screen_ocr" => Self::ScreenOcr,
            "browser_page" => Self::BrowserPage,
            "browser_page_with_ocr" => Self::BrowserPageWithOcr,
            "transcript_import" => Self::TranscriptImport,
            "structured_app" => Self::StructuredApp,
            "mcp_resource" => Self::McpResource,
            _ => Self::Unknown,
        }
    }
}

/// Retained database counts, never helper uptime counters.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct CaptureStorageStats {
    /// Retained events whose recorded producer includes screen OCR.
    pub stored_frame_count: u64,
    /// Retained database references to keyframe blobs, not filesystem files.
    pub stored_screenshot_count: u64,
    /// Latest retained screen event timestamp, if known.
    pub last_stored_frame_ts_us: Option<u64>,
}
