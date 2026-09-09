//! Synthetic sequential policy evaluation. No agent or provider is invoked.

#[path = "../sequential_memory/mod.rs"]
mod sequential_memory;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    if arguments == ["--policy-client"] {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take((sequential_memory::REQUEST_BYTE_LIMIT + 1) as u64)
            .read_to_end(&mut bytes)?;
        if bytes.len() > sequential_memory::REQUEST_BYTE_LIMIT {
            return Err("client request exceeds byte budget".into());
        }
        let request = serde_json::from_slice(&bytes)?;
        let response = sequential_memory::policy_client(&request)?;
        println!("{}", serde_json::to_string(&response)?);
        return Ok(());
    }
    let mut output = None;
    let mut requests_output = None;
    let mut args = arguments.iter();
    while let Some(argument) = args.next() {
        match argument.as_str() {
            "--out" => output = Some(args.next().ok_or("--out requires an absolute path")?),
            "--requests-out" => requests_output = Some(args.next().ok_or("--requests-out requires an absolute path")?),
            _ => return Err("usage: sequential-memory-eval [--out PATH] [--requests-out PATH] | --policy-client".into()),
        }
    }
    for path in [output, requests_output].into_iter().flatten() {
        if !std::path::Path::new(path).is_absolute() {
            return Err("output paths must be absolute".into());
        }
    }
    if output.is_some() && output == requests_output {
        return Err("report and client requests must use separate files".into());
    }
    let evaluation = sequential_memory::evaluate()?;
    let report = serde_json::to_string_pretty(&evaluation.report)?;
    if let Some(path) = output {
        std::fs::write(path, report + "\n")?;
    } else {
        println!("{report}");
    }
    if let Some(path) = requests_output {
        std::fs::write(
            path,
            serde_json::to_string_pretty(&evaluation.requests)? + "\n",
        )?;
    }
    Ok(())
}
