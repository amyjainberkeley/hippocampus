Deep-work day on the brief-quality eval scorer

What shipped
- Wrote the citation_validity metric in scorer.rs with a unit test for hallucinated event ids [event:11]
- Fixed a parse_citations edge case for missing closing brackets — workspace cargo test came back clean [event:13]
- Drafted docs/eval/brief-quality.md with a worked example of the scorer breakdown [event:16]
- Filed PR for the brief-quality eval framework on the director-brain branch [event:18]

What changed
- Added EvalReport::render_text so the runner prints a per-fixture PASS/FAIL table [event:14]
- Ran cargo test --workspace once everything was wired — 540 passing [event:15]

###CITATIONS: [event:11], [event:13], [event:14], [event:15], [event:16], [event:18]
