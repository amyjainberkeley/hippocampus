//! Media Foundation hardware H.264/HEVC encoder for Windows.
//!
//! Windows equivalent of macOS `VideoToolboxHEVCEncoder`. Uses the Media
//! Foundation transform pipeline (`IMFTransform`) with hardware MFTs
//! (Intel QSV / NVIDIA NVENC / AMD VCE) for near-zero-CPU encode of
//! captured frames.
//!
//! # Encode budget
//!
//! Same constraint as macOS: encode MUST NOT exceed the footprint SLO
//! (≤ ~1-2% CPU sustained, ≤ 250 MB RAM). Hardware MFTs offload to the
//! GPU media engine, keeping CPU overhead negligible.
//!
//! # Cascade-before-encode invariant (ADR-0013 §5)
//!
//! Encode is NEVER called before the suppression cascade has decided
//! `.allow`. This is enforced in the portable Rust pipeline, not in
//! this encoder module — but the encoder API is designed to make
//! "encode then decide" structurally impossible (no auto-start, no
//! buffering of un-decided frames).

/// Supported hardware encoder backends on Windows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HardwareEncoder {
    /// Intel Quick Sync Video (QSV) via Media Foundation.
    IntelQsv,
    /// NVIDIA NVENC via Media Foundation.
    NvidiaNvenc,
    /// AMD Video Core Engine via Media Foundation.
    AmdVce,
    /// Software fallback (Microsoft H.264 Encoder MFT).
    Software,
}

/// Configuration for the Media Foundation encoder session.
#[derive(Debug, Clone)]
pub struct EncoderConfig {
    pub width: u32,
    pub height: u32,
    pub target_bitrate_kbps: u32,
    pub codec: VideoCodec,
}

/// Video codec selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    H264,
    Hevc,
}

/// Detect available hardware encoder on this machine.
///
/// Enumerates registered MFTs matching `MFT_CATEGORY_VIDEO_ENCODER` and
/// checks for hardware-accelerated transforms.
pub fn detect_hardware_encoder() -> HardwareEncoder {
    unimplemented!("Phase 8: MFT enumeration for hardware encoder detection")
}

/// Create and configure a Media Foundation encoder session.
///
/// Sets up the `IMFTransform` pipeline with input/output media types,
/// configures the bitrate controller, and prepares for frame submission.
pub fn create_encoder_session(_config: &EncoderConfig) -> ! {
    unimplemented!("Phase 8: IMFTransform encoder session creation")
}

/// Submit a frame to the encoder.
///
/// Accepts raw pixel data (NV12 or BGRA from the capture surface) and
/// produces encoded NAL units. Returns encoded bytes or signals that
/// more input is needed.
pub fn encode_frame(_pixels: &[u8], _timestamp_100ns: u64) -> ! {
    unimplemented!("Phase 8: IMFTransform ProcessInput + ProcessOutput")
}

/// Flush the encoder and retrieve any buffered output.
pub fn flush_encoder() -> ! {
    unimplemented!("Phase 8: IMFTransform drain + flush")
}
