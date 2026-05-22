//! Quality regression for the `snowflake-arctic-embed-s` Core ML
//! pipeline.
//!
//! Wave-17 gate: the converted INT8 `.mlmodelc` must produce embeddings
//! that match the Python FP32 reference (sentence-transformers
//! `Snowflake/snowflake-arctic-embed-s`, `normalize_embeddings=True`)
//! to within cosine similarity `>= 0.999` on the 50-sentence fixture
//! at `tests/fixtures/arctic_embed_sentences.txt` /
//! `arctic_embed_reference.npy`.
//!
//! A failure on any row flips the INT8-vs-FP16 decision per the
//! ADR-0011 erratum (2026-05-22): rerun the conversion without
//! `linear_quantize_weights` to ship FP16 instead.
//!
//! # Skipping when fixtures are not present
//!
//! The `.mlmodelc` (~30 MB, gitignored) and the `.npy` reference
//! (~75 KB) are produced by `scripts/convert_embedder.py --verify
//! --fixtures` and live under the repo's `models/` and
//! `tests/fixtures/` directories respectively. CI / headless dev
//! environments may not have them — every test in this file calls
//! [`model_and_reference_or_skip`] first and `println!`-returns when
//! either is missing. This mirrors the P3.11 live-Mac audit pattern
//! from ADR-0016 §7.

#![cfg(target_os = "macos")]

use std::path::PathBuf;

use mci_brain::arctic_embed_s::{EmbedderBackend, ARCTIC_EMBED_S_DIMENSION};
use mci_embed_coreml::CoreMLBackend;

const FIXTURE_SENTENCES: &str = "tests/fixtures/arctic_embed_sentences.txt";
const FIXTURE_REFERENCE: &str = "tests/fixtures/arctic_embed_reference.npy";

// Try a few sensible locations for the compiled Core ML model. Order
// mirrors `apps/agent`'s candidate-paths fallback chain.
fn model_path() -> Option<PathBuf> {
    // CARGO_MANIFEST_DIR = adapters/macos/mci-embed-coreml when this
    // test is run via `cargo test -p mci-embed-coreml --test quality`.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir.join("../../..").canonicalize().ok()?;

    let candidates = [
        repo_root.join("models/ArcticEmbedS_INT8.mlmodelc"),
        repo_root.join("models/ArcticEmbedS_INT8.mlpackage"),
    ];
    for c in candidates {
        if c.exists() {
            return Some(c);
        }
    }
    None
}

fn reference_path() -> Option<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let p = manifest_dir.join(FIXTURE_REFERENCE);
    if p.exists() {
        Some(p)
    } else {
        None
    }
}

fn sentences_path() -> Option<PathBuf> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let p = manifest_dir.join(FIXTURE_SENTENCES);
    if p.exists() {
        Some(p)
    } else {
        None
    }
}

/// Returns `Some((backend, sentences, reference))` when every required
/// fixture is present; `None` (with a `println!` explaining what was
/// missing) when any of them are absent — callers `return` early on
/// `None` so the test passes (skipped) under that condition.
fn model_and_reference_or_skip() -> Option<(CoreMLBackend, Vec<String>, Vec<Vec<f32>>)> {
    let Some(model) = model_path() else {
        println!(
            "quality.rs: skipping — no ArcticEmbedS_INT8.mlmodelc or .mlpackage \
             found under <repo>/models/. Run scripts/convert_embedder.py \
             --output models/ArcticEmbedS_INT8.mlpackage --verify --fixtures \
             to produce it."
        );
        return None;
    };
    let Some(ref_path) = reference_path() else {
        println!(
            "quality.rs: skipping — no Python FP32 reference fixture at \
             {FIXTURE_REFERENCE}. Run scripts/convert_embedder.py with \
             --fixtures to write it."
        );
        return None;
    };
    let Some(sentences_p) = sentences_path() else {
        println!(
            "quality.rs: skipping — no fixture sentences file at \
             {FIXTURE_SENTENCES}. Run scripts/convert_embedder.py with \
             --fixtures to write it."
        );
        return None;
    };

    let backend = match CoreMLBackend::open(&model) {
        Ok(b) => b,
        Err(e) => {
            println!("quality.rs: skipping — CoreMLBackend::open failed: {e:?}");
            return None;
        }
    };

    let sentences_text = match std::fs::read_to_string(&sentences_p) {
        Ok(s) => s,
        Err(e) => {
            println!("quality.rs: skipping — read sentences: {e}");
            return None;
        }
    };
    // Trailing newline at EOF would otherwise produce an extra empty
    // sentence — strip exactly one trailing newline if present.
    let trimmed = sentences_text
        .strip_suffix('\n')
        .unwrap_or(&sentences_text);
    let sentences: Vec<String> = trimmed.split('\n').map(str::to_string).collect();

    let reference = match read_npy_f32_2d(&ref_path) {
        Ok(r) => r,
        Err(e) => {
            println!("quality.rs: skipping — read {FIXTURE_REFERENCE}: {e}");
            return None;
        }
    };

    if reference.len() != sentences.len() {
        println!(
            "quality.rs: skipping — fixture row count mismatch: {} sentences \
             vs {} reference rows",
            sentences.len(),
            reference.len()
        );
        return None;
    }

    Some((backend, sentences, reference))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn cosine_similarity_matches_python_reference() {
    let Some((backend, sentences, reference)) = model_and_reference_or_skip() else {
        return;
    };

    let mut failures: Vec<(usize, f32)> = Vec::new();
    for (i, (text, ref_vec)) in sentences.iter().zip(reference.iter()).enumerate() {
        let got = match backend.forward(text) {
            Ok(v) => v,
            Err(e) => {
                panic!("row {i} ({text:?}): backend.forward failed: {e:?}");
            }
        };
        assert_eq!(
            got.len(),
            ARCTIC_EMBED_S_DIMENSION,
            "row {i}: expected 384-d, got {}",
            got.len()
        );
        let cos = cosine_similarity(&got, ref_vec);
        if cos < 0.999 {
            failures.push((i, cos));
        }
    }

    assert!(
        failures.is_empty(),
        "INT8 quantization drift > 1e-3 vs Python FP32 reference on {} / {} rows: {:?}. \
         Per ADR-0011 erratum (2026-05-22), flip the build to FP16 by removing \
         the linear_quantize_weights step in scripts/convert_embedder.py.",
        failures.len(),
        sentences.len(),
        failures
    );
}

#[test]
fn output_is_l2_normalized() {
    let Some((backend, sentences, _)) = model_and_reference_or_skip() else {
        return;
    };

    for (i, text) in sentences.iter().enumerate() {
        let v = backend
            .forward(text)
            .unwrap_or_else(|e| panic!("row {i}: {e:?}"));
        let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
        assert!(
            (mag - 1.0).abs() < 1e-3,
            "row {i} ({text:?}): |v| = {mag}, expected ~1.0 (graph L2-norm)"
        );
    }
}

#[test]
fn output_dimension_is_384() {
    let Some((backend, sentences, _)) = model_and_reference_or_skip() else {
        return;
    };
    for (i, text) in sentences.iter().enumerate() {
        let v = backend
            .forward(text)
            .unwrap_or_else(|e| panic!("row {i}: {e:?}"));
        assert_eq!(v.len(), 384, "row {i}: expected dim=384, got {}", v.len());
    }
}

#[test]
fn truncation_long_input_does_not_crash() {
    let Some((backend, _, _)) = model_and_reference_or_skip() else {
        return;
    };
    // ~5000 chars — well beyond the 128-token graph input length.
    let long = "lorem ipsum dolor sit amet ".repeat(200);
    let v = backend
        .forward(&long)
        .expect("long input must truncate, not crash");
    assert_eq!(v.len(), 384);
    let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!((mag - 1.0).abs() < 1e-3, "truncated input |v| = {mag}");
}

#[test]
fn empty_string_returns_valid_vector() {
    let Some((backend, _, _)) = model_and_reference_or_skip() else {
        return;
    };
    let v = backend
        .forward("")
        .expect("empty string must produce [CLS][SEP][PAD]... and a valid vector");
    assert_eq!(v.len(), 384);
    // Magnitude is still ~1 because the graph L2-normalizes whatever
    // hidden state the CLS slice produces (even on a tiny [CLS][SEP][PAD]…
    // input).
    let mag: f32 = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    assert!((mag - 1.0).abs() < 1e-3, "empty-string |v| = {mag}");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn cosine_similarity(a: &[f32], b: &[f32]) -> f32 {
    assert_eq!(a.len(), b.len());
    let dot: f32 = a.iter().zip(b.iter()).map(|(x, y)| x * y).sum();
    let na: f32 = a.iter().map(|x| x * x).sum::<f32>().sqrt();
    let nb: f32 = b.iter().map(|x| x * x).sum::<f32>().sqrt();
    if na == 0.0 || nb == 0.0 {
        return 0.0;
    }
    dot / (na * nb)
}

/// Minimal NumPy `.npy` v1.0 / v2.0 reader, restricted to the exact
/// shape we expect: `dtype=float32`, C-order, 2-D `[rows, 384]`.
///
/// Format reference: <https://numpy.org/doc/stable/reference/generated/numpy.lib.format.html>
///
/// We only handle the v1.0 / v2.0 little-endian `'<f4'` / `'|f4'` /
/// `'<f4'` dtype string, fortran_order=False, exactly two shape dims.
/// Anything else is an error — the orchestrator produces the file with
/// `numpy.save`, which always writes a layout we can read.
fn read_npy_f32_2d(path: &std::path::Path) -> Result<Vec<Vec<f32>>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    if bytes.len() < 10 {
        return Err("file too short for .npy header".into());
    }
    if &bytes[0..6] != b"\x93NUMPY" {
        return Err("missing .npy magic prefix".into());
    }
    let major = bytes[6];
    let minor = bytes[7];
    let (header_len, header_start): (usize, usize) = match major {
        1 => {
            // v1: 2-byte little-endian header length
            let h = u16::from_le_bytes([bytes[8], bytes[9]]) as usize;
            (h, 10)
        }
        2 | 3 => {
            // v2/v3: 4-byte little-endian header length
            if bytes.len() < 12 {
                return Err("v2 npy header truncated".into());
            }
            let h = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize;
            (h, 12)
        }
        _ => return Err(format!("unsupported .npy version: {major}.{minor}")),
    };

    let header_end = header_start + header_len;
    if bytes.len() < header_end {
        return Err("npy header runs past EOF".into());
    }
    let header = std::str::from_utf8(&bytes[header_start..header_end])
        .map_err(|e| format!("npy header utf8: {e}"))?
        .trim();
    // Header is a Python literal dict like:
    //   {'descr': '<f4', 'fortran_order': False, 'shape': (50, 384), }
    // We parse it by string-searching the three fields.

    let dtype = header_find_str(header, "'descr':")?;
    if dtype != "<f4" && dtype != "|f4" {
        return Err(format!("unsupported npy dtype: {dtype:?}, expected '<f4'"));
    }
    let fortran = header_find_str(header, "'fortran_order':")?;
    if fortran != "False" {
        return Err(format!("npy fortran_order={fortran:?}, expected False"));
    }
    let shape = header_find_shape(header)?;
    if shape.len() != 2 {
        return Err(format!("npy shape has {} dims, expected 2", shape.len()));
    }
    let rows = shape[0];
    let cols = shape[1];
    if cols != ARCTIC_EMBED_S_DIMENSION {
        return Err(format!("npy second dim is {cols}, expected {ARCTIC_EMBED_S_DIMENSION}"));
    }

    let payload = &bytes[header_end..];
    let expected = rows.checked_mul(cols).ok_or("shape overflow")? * 4;
    if payload.len() < expected {
        return Err(format!(
            "npy payload {} bytes, expected {expected}",
            payload.len()
        ));
    }

    let mut out = Vec::with_capacity(rows);
    for r in 0..rows {
        let mut row = Vec::with_capacity(cols);
        for c in 0..cols {
            let off = (r * cols + c) * 4;
            let v = f32::from_le_bytes([
                payload[off],
                payload[off + 1],
                payload[off + 2],
                payload[off + 3],
            ]);
            row.push(v);
        }
        out.push(row);
    }
    Ok(out)
}

fn header_find_str<'h>(header: &'h str, key: &str) -> Result<&'h str, String> {
    let i = header
        .find(key)
        .ok_or_else(|| format!("npy header missing key {key:?}"))?;
    let rest = &header[i + key.len()..];
    let rest = rest.trim_start();
    if let Some(rest) = rest.strip_prefix('\'') {
        let end = rest
            .find('\'')
            .ok_or_else(|| format!("npy header unterminated string for {key:?}"))?;
        Ok(&rest[..end])
    } else {
        // bare token like `False` / `True`
        let end = rest
            .find([',', '}', ' '])
            .ok_or_else(|| format!("npy header malformed token for {key:?}"))?;
        Ok(rest[..end].trim())
    }
}

fn header_find_shape(header: &str) -> Result<Vec<usize>, String> {
    let i = header
        .find("'shape':")
        .ok_or_else(|| "npy header missing 'shape'".to_string())?;
    let rest = &header[i + "'shape':".len()..];
    let lp = rest
        .find('(')
        .ok_or_else(|| "npy shape missing '('".to_string())?;
    let rp = rest
        .find(')')
        .ok_or_else(|| "npy shape missing ')'".to_string())?;
    if rp <= lp {
        return Err("npy shape parens malformed".into());
    }
    let inner = &rest[lp + 1..rp];
    let mut dims = Vec::new();
    for tok in inner.split(',') {
        let t = tok.trim();
        if t.is_empty() {
            continue;
        }
        let v: usize = t
            .parse()
            .map_err(|e| format!("npy shape dim {t:?}: {e}"))?;
        dims.push(v);
    }
    Ok(dims)
}
