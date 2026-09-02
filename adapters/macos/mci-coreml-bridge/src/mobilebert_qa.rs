//! `MobileBERT` `SQuAD2` question-answering candidate over the generic Core ML
//! bridge.
//!
//! This module is an evaluation adapter, not a qualified production evidence
//! verifier. It keeps tokenization, model IO, and extractive span decoding
//! below the adapter boundary so higher layers receive a small safe result.

use std::cmp::Ordering;
use std::ops::Range;
use std::path::Path;

use tokenizers::{
    PaddingDirection, PaddingParams, PaddingStrategy, Tokenizer, TruncationDirection,
    TruncationParams, TruncationStrategy,
};

use crate::model::{self, ComputeUnits, CoreMLError, CoreMLModel};

const SEQUENCE_LENGTH: usize = 384;
const MAX_ANSWER_TOKENS: usize = 24;

/// Errors produced while opening or evaluating the QA candidate.
#[derive(Debug, thiserror::Error)]
pub enum MobileBertQaError {
    /// The tokenizer could not be loaded or applied.
    #[error("tokenizer error: {0}")]
    Tokenizer(String),
    /// The Core ML model failed to load or predict.
    #[error("Core ML error: {0}")]
    CoreMl(#[from] CoreMLError),
    /// The candidate artifact does not expose the frozen QA schema.
    #[error("invalid MobileBERT QA model: {0}")]
    Schema(String),
    /// Model output was non-finite or could not map to canonical context.
    #[error("invalid MobileBERT QA output: {0}")]
    Output(String),
}

/// One extractive answer from canonical evidence text.
#[derive(Debug, Clone, PartialEq)]
pub struct QaAnswer {
    /// Exact substring of the supplied context.
    pub text: String,
    /// Byte range inside the supplied context.
    pub byte_range: Range<usize>,
    /// Best span score minus the `SQuAD2` CLS no-answer score.
    pub no_answer_margin: f32,
}

/// Fixed-shape FP32 `MobileBERT` QA runtime used by the verifier bake-off.
#[derive(Debug)]
pub struct MobileBertQaBackend {
    model: CoreMLModel,
    tokenizer: Tokenizer,
}

impl MobileBertQaBackend {
    /// Open a compiled model and Hugging Face `tokenizer.json`.
    pub fn open(model_path: &Path, tokenizer_path: &Path) -> Result<Self, MobileBertQaError> {
        let model = CoreMLModel::load_with_compute_units(model_path, ComputeUnits::CpuOnly)?;
        let tokenizer = Tokenizer::from_file(tokenizer_path).map_err(|error| {
            MobileBertQaError::Tokenizer(format!("{}: {error}", tokenizer_path.display()))
        })?;
        let backend = Self { model, tokenizer };
        backend.verify_schema()?;
        Ok(backend)
    }

    fn verify_schema(&self) -> Result<(), MobileBertQaError> {
        for name in ["input_ids", "attention_mask", "token_type_ids"] {
            if !self.model.has_input(name) {
                return Err(MobileBertQaError::Schema(format!(
                    "missing required input {name:?}"
                )));
            }
        }
        for name in ["start_logits", "end_logits"] {
            match self.model.output_is_multi_array(name) {
                Some(true) => {}
                Some(false) => {
                    return Err(MobileBertQaError::Schema(format!(
                        "output {name:?} is not a MultiArray"
                    )));
                }
                None => {
                    return Err(MobileBertQaError::Schema(format!(
                        "missing required output {name:?}"
                    )));
                }
            }
        }
        Ok(())
    }

    /// Extract the strongest answer span for one question/evidence pair.
    pub fn answer(&self, question: &str, context: &str) -> Result<QaAnswer, MobileBertQaError> {
        let mut tokenizer = self.tokenizer.clone();
        tokenizer.with_padding(Some(PaddingParams {
            strategy: PaddingStrategy::Fixed(SEQUENCE_LENGTH),
            direction: PaddingDirection::Right,
            pad_to_multiple_of: None,
            pad_id: 0,
            pad_type_id: 0,
            pad_token: "[PAD]".to_owned(),
        }));
        tokenizer
            .with_truncation(Some(TruncationParams {
                max_length: SEQUENCE_LENGTH,
                strategy: TruncationStrategy::OnlySecond,
                stride: 0,
                direction: TruncationDirection::Right,
            }))
            .map_err(|error| MobileBertQaError::Tokenizer(error.to_string()))?;
        let encoding = tokenizer
            .encode((question, context), true)
            .map_err(|error| MobileBertQaError::Tokenizer(error.to_string()))?;

        let input_ids = u32_to_i32(encoding.get_ids());
        let attention_mask = u32_to_i32(encoding.get_attention_mask());
        let type_ids = u32_to_i32(encoding.get_type_ids());
        let input_ids_array = model::multi_array_i32(&[1, SEQUENCE_LENGTH], &input_ids)?;
        let attention_mask_array = model::multi_array_i32(&[1, SEQUENCE_LENGTH], &attention_mask)?;
        let type_ids_array = model::multi_array_i32(&[1, SEQUENCE_LENGTH], &type_ids)?;
        let prediction = self.model.predict(&[
            ("input_ids", &input_ids_array),
            ("attention_mask", &attention_mask_array),
            ("token_type_ids", &type_ids_array),
        ])?;
        let start_array = prediction.multi_array("start_logits")?;
        let end_array = prediction.multi_array("end_logits")?;
        if model::multi_array_len(&start_array) != SEQUENCE_LENGTH
            || model::multi_array_len(&end_array) != SEQUENCE_LENGTH
        {
            return Err(MobileBertQaError::Output(
                "logit output length does not match the frozen sequence length".to_owned(),
            ));
        }
        let start_logits = model::read_f32_slice(&start_array, 0, SEQUENCE_LENGTH)?;
        let end_logits = model::read_f32_slice(&end_array, 0, SEQUENCE_LENGTH)?;

        select_best_span(
            context,
            &start_logits,
            &end_logits,
            &type_ids,
            &attention_mask,
            encoding.get_offsets(),
            MAX_ANSWER_TOKENS,
        )
        .ok_or_else(|| {
            MobileBertQaError::Output("no finite context answer span was available".to_owned())
        })
    }
}

#[allow(clippy::cast_possible_wrap)]
fn u32_to_i32(values: &[u32]) -> Vec<i32> {
    values.iter().map(|&value| value as i32).collect()
}

fn select_best_span(
    context: &str,
    start_logits: &[f32],
    end_logits: &[f32],
    type_ids: &[i32],
    attention_mask: &[i32],
    offsets: &[(usize, usize)],
    max_answer_tokens: usize,
) -> Option<QaAnswer> {
    let length = start_logits.len();
    if length == 0
        || end_logits.len() != length
        || type_ids.len() != length
        || attention_mask.len() != length
        || offsets.len() != length
        || !start_logits[0].is_finite()
        || !end_logits[0].is_finite()
    {
        return None;
    }

    let no_answer_score = start_logits[0] + end_logits[0];
    let mut best: Option<(f32, usize, usize)> = None;
    for start in 0..length {
        if type_ids[start] != 1
            || attention_mask[start] == 0
            || offsets[start].0 >= offsets[start].1
            || !start_logits[start].is_finite()
        {
            continue;
        }
        let end_exclusive = start.saturating_add(max_answer_tokens.max(1)).min(length);
        for end in start..end_exclusive {
            if type_ids[end] != 1
                || attention_mask[end] == 0
                || offsets[end].0 >= offsets[end].1
                || !end_logits[end].is_finite()
            {
                continue;
            }
            let byte_range = offsets[start].0..offsets[end].1;
            if byte_range.start >= byte_range.end
                || byte_range.end > context.len()
                || !context.is_char_boundary(byte_range.start)
                || !context.is_char_boundary(byte_range.end)
            {
                continue;
            }
            let score = start_logits[start] + end_logits[end];
            let should_replace = best.is_none_or(|(best_score, best_start, best_end)| {
                score.total_cmp(&best_score) == Ordering::Greater
                    || (score.total_cmp(&best_score) == Ordering::Equal
                        && (end - start, start, end)
                            < (best_end - best_start, best_start, best_end))
            });
            if should_replace {
                best = Some((score, start, end));
            }
        }
    }

    let (score, start, end) = best?;
    let byte_range = offsets[start].0..offsets[end].1;
    Some(QaAnswer {
        text: context.get(byte_range.clone())?.to_owned(),
        byte_range,
        no_answer_margin: score - no_answer_score,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn best_span_is_context_only_and_reports_no_answer_margin() {
        let start_logits = [8.0, 20.0, 1.0, 9.0, 2.0];
        let end_logits = [8.0, 20.0, 1.0, 3.0, 10.0];
        let type_ids = [0, 0, 0, 1, 1];
        let attention_mask = [1, 1, 1, 1, 1];
        let offsets = [(0, 0), (0, 5), (0, 0), (0, 5), (6, 11)];

        let answer = select_best_span(
            "alpha omega",
            &start_logits,
            &end_logits,
            &type_ids,
            &attention_mask,
            &offsets,
            8,
        )
        .expect("context answer");

        assert_eq!(answer.text, "alpha omega");
        assert_eq!(answer.byte_range, 0..11);
        assert!((answer.no_answer_margin - 3.0).abs() < f32::EPSILON);
    }
}
