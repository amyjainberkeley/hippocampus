use std::path::PathBuf;
use std::process::ExitCode;

use mci_agent_handoff_eval::{evaluate_raw, Arm};

fn usage() {
    eprintln!(
        "Usage: mci-agent-handoff-eval --dataset PATH --out PATH \
         [--arm lexical|hybrid|both]"
    );
}

fn run() -> Result<(), String> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    let mut dataset = None;
    let mut out = None;
    let mut arms = vec![Arm::Lexical, Arm::Hybrid];
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--dataset" if index + 1 < arguments.len() => {
                dataset = Some(PathBuf::from(&arguments[index + 1]));
                index += 2;
            }
            "--out" if index + 1 < arguments.len() => {
                out = Some(PathBuf::from(&arguments[index + 1]));
                index += 2;
            }
            "--arm" if index + 1 < arguments.len() => {
                arms = match arguments[index + 1].as_str() {
                    "lexical" => vec![Arm::Lexical],
                    "hybrid" => vec![Arm::Hybrid],
                    "both" => vec![Arm::Lexical, Arm::Hybrid],
                    value => return Err(format!("unknown arm {value:?}")),
                };
                index += 2;
            }
            "-h" | "--help" => {
                usage();
                return Ok(());
            }
            value => return Err(format!("unknown or incomplete argument {value:?}")),
        }
    }
    let dataset = dataset.ok_or_else(|| "--dataset is required".to_owned())?;
    let out = out.ok_or_else(|| "--out is required".to_owned())?;
    let corpus = std::fs::read_to_string(&dataset)
        .map_err(|error| format!("read {}: {error}", dataset.display()))?;
    let report = evaluate_raw(&corpus, &arms)?;
    let serialized = serde_json::to_string_pretty(&report)
        .map_err(|error| format!("serialize raw report: {error}"))?;
    std::fs::write(&out, serialized + "\n")
        .map_err(|error| format!("write {}: {error}", out.display()))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            usage();
            eprintln!("mci-agent-handoff-eval: {error}");
            ExitCode::from(2)
        }
    }
}
