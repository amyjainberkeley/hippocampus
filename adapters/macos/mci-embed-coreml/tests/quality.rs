//! Quality regression for the `snowflake-arctic-embed-s` Core ML
//! pipeline.
//!
//! Shipping gate: the converted FP16 `.mlmodelc` must produce embeddings
//! that match the Python FP32 reference (sentence-transformers
//! `Snowflake/snowflake-arctic-embed-s`, `normalize_embeddings=True`)
//! to within cosine similarity `>= 0.999` on the 50-sentence fixture
//! at `tests/fixtures/arctic_embed_sentences.txt` /
//! `arctic_embed_reference.npy`.
//!
//! INT8 already failed this gate on 43/50 rows. A failure on the FP16
//! artifact is a conversion regression and blocks packaging.
//!
//! # Skipping when fixtures are not present
//!
//! The `.mlmodelc` (~66 MB, gitignored) and the `.npy` reference
//! (~75 KB) are produced by `scripts/convert_embedder.py --verify
//! --fixtures` and live under the repo's `models/` and
//! `tests/fixtures/` directories respectively. CI / headless dev
//! environments may not have them. Local tests print and return when
//! an artifact is absent. Release CI sets `MCI_REQUIRE_COREML_QUALITY=1`,
//! which makes an absent or unreadable artifact a hard failure.

#![cfg(target_os = "macos")]

use std::{path::PathBuf, time::Instant};

use mci_brain::arctic_embed_s::{EmbedderBackend, ARCTIC_EMBED_S_DIMENSION};
use mci_embed_coreml::{ComputeUnits, CoreMLBackend};

const FIXTURE_SENTENCES: &str = "tests/fixtures/arctic_embed_sentences.txt";
const FIXTURE_REFERENCE: &str = "tests/fixtures/arctic_embed_reference.npy";
const EXPECTED_FIXTURE_ROWS: usize = 50;

// Try a few sensible locations for the compiled Core ML model. Order
// mirrors `apps/agent`'s candidate-paths fallback chain.
fn model_path() -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("MCI_ARCTIC_MODEL_PATH") {
        return Some(PathBuf::from(explicit));
    }
    // CARGO_MANIFEST_DIR = adapters/macos/mci-embed-coreml when this
    // test is run via `cargo test -p mci-embed-coreml --test quality`.
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir.join("../../..").canonicalize().ok()?;

    let candidates = [
        repo_root.join("models/ArcticEmbedS_FP16.mlmodelc"),
        repo_root.join("models/ArcticEmbedS_FP16.mlpackage"),
    ];
    candidates.into_iter().find(|candidate| candidate.exists())
}

fn quality_gate_required() -> bool {
    std::env::var_os("MCI_REQUIRE_COREML_QUALITY").is_some()
}

fn unavailable<T>(message: impl AsRef<str>) -> Option<T> {
    let message = message.as_ref();
    assert!(
        !quality_gate_required(),
        "quality.rs: release quality gate unavailable: {message}"
    );
    println!("quality.rs: skipping - {message}");
    None
}

fn validate_fixture_cardinality(
    sentences: &[String],
    reference: &[Vec<f32>],
) -> Result<(), String> {
    if sentences.len() != EXPECTED_FIXTURE_ROWS {
        return Err(format!(
            "expected exactly {EXPECTED_FIXTURE_ROWS} fixture sentences, found {}",
            sentences.len()
        ));
    }
    if reference.len() != EXPECTED_FIXTURE_ROWS {
        return Err(format!(
            "expected exactly {EXPECTED_FIXTURE_ROWS} reference rows, found {}",
            reference.len()
        ));
    }
    Ok(())
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
        return unavailable(
            "no ArcticEmbedS_FP16.mlmodelc or .mlpackage \
             found under <repo>/models/. Run scripts/convert_embedder.py \
             --output models/ArcticEmbedS_FP16.mlpackage --verify --fixtures \
             to produce it.",
        );
    };
    let Some(ref_path) = reference_path() else {
        return unavailable(
            "no Python FP32 reference fixture at \
             {FIXTURE_REFERENCE}. Run scripts/convert_embedder.py with \
             --fixtures to write it.",
        );
    };
    let Some(sentences_p) = sentences_path() else {
        return unavailable(
            "no fixture sentences file at \
             {FIXTURE_SENTENCES}. Run scripts/convert_embedder.py with \
             --fixtures to write it.",
        );
    };

    let backend = match CoreMLBackend::open(&model) {
        Ok(b) => b,
        Err(e) => {
            return unavailable(format!("CoreMLBackend::open failed: {e:?}"));
        }
    };

    let sentences_text = match std::fs::read_to_string(&sentences_p) {
        Ok(s) => s,
        Err(e) => {
            return unavailable(format!("read sentences: {e}"));
        }
    };
    // Trailing newline at EOF would otherwise produce an extra empty
    // sentence — strip exactly one trailing newline if present.
    let trimmed = sentences_text.strip_suffix('\n').unwrap_or(&sentences_text);
    let sentences: Vec<String> = trimmed.split('\n').map(str::to_string).collect();

    let reference = match read_npy_f32_2d(&ref_path) {
        Ok(r) => r,
        Err(e) => {
            return unavailable(format!("read {FIXTURE_REFERENCE}: {e}"));
        }
    };

    if let Err(error) = validate_fixture_cardinality(&sentences, &reference) {
        return unavailable(error);
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
        "FP16 conversion drift > 1e-3 vs Python FP32 reference on {} / {} rows: {:?}. \
         The shipping model no longer matches its pinned source checkpoint.",
        failures.len(),
        sentences.len(),
        failures
    );
}

#[test]
fn shipping_graph_is_finite_and_matches_reference_on_cpu_and_neural_engine() {
    let Some(model) = model_path() else {
        unavailable::<()>("dual-compute gate has no compiled model");
        return;
    };
    let Some(ref_path) = reference_path() else {
        unavailable::<()>("dual-compute gate has no reference fixture");
        return;
    };
    let Some(sentences_p) = sentences_path() else {
        unavailable::<()>("dual-compute gate has no sentence fixture");
        return;
    };
    let sentences_text = std::fs::read_to_string(sentences_p).expect("read fixture sentences");
    let sentences: Vec<String> = sentences_text
        .strip_suffix('\n')
        .unwrap_or(&sentences_text)
        .split('\n')
        .map(str::to_string)
        .collect();
    let reference = read_npy_f32_2d(&ref_path).expect("read FP32 reference fixture");
    validate_fixture_cardinality(&sentences, &reference)
        .unwrap_or_else(|error| panic!("invalid shipping quality fixture: {error}"));
    let sentence_count = u32::try_from(sentences.len()).expect("fixture count fits in u32");

    for units in [ComputeUnits::CpuOnly, ComputeUnits::CpuAndNeuralEngine] {
        let backend = CoreMLBackend::open_with_compute_units(&model, units)
            .unwrap_or_else(|error| panic!("load {units:?}: {error:?}"));
        let started = Instant::now();
        for (row, (sentence, expected)) in sentences.iter().zip(&reference).enumerate() {
            let actual = backend
                .forward(sentence)
                .unwrap_or_else(|error| panic!("{units:?} row {row}: {error:?}"));
            assert!(
                actual.iter().all(|value| value.is_finite()),
                "{units:?} row {row} produced a non-finite embedding"
            );
            let cosine = cosine_similarity(&actual, expected);
            assert!(
                cosine >= 0.999,
                "{units:?} row {row} ({sentence:?}) cosine={cosine}, expected >= 0.999"
            );
        }
        println!(
            "{units:?}: {:.2} ms/embedding across {} reference sentences",
            started.elapsed().as_secs_f64() * 1_000.0 / f64::from(sentence_count),
            sentences.len()
        );
    }
}

#[test]
fn shipping_fixture_cardinality_is_exactly_fifty() {
    let fifty_sentences = vec![String::new(); EXPECTED_FIXTURE_ROWS];
    let fifty_references = vec![Vec::new(); EXPECTED_FIXTURE_ROWS];
    assert!(validate_fixture_cardinality(&fifty_sentences, &fifty_references).is_ok());
    assert!(validate_fixture_cardinality(&fifty_sentences[..49], &fifty_references).is_err());
    assert!(validate_fixture_cardinality(&fifty_sentences, &fifty_references[..49]).is_err());
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

/// Minimal `NumPy` `.npy` v1.0 / v2.0 reader, restricted to the exact
/// shape we expect: `dtype=float32`, C-order, 2-D `[rows, 384]`.
///
/// Format reference: <https://numpy.org/doc/stable/reference/generated/numpy.lib.format.html>
///
/// We only handle the v1.0 / v2.0 little-endian `'<f4'` / `'|f4'` /
/// `'<f4'` dtype string, `fortran_order=False`, exactly two shape dims.
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
        return Err(format!(
            "npy second dim is {cols}, expected {ARCTIC_EMBED_S_DIMENSION}"
        ));
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
        let v: usize = t.parse().map_err(|e| format!("npy shape dim {t:?}: {e}"))?;
        dims.push(v);
    }
    Ok(dims)
}
