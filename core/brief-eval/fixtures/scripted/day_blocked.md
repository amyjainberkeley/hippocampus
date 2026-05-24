Blocked on Qwen3 Core ML load — pairing with ML eng tomorrow

What's blocked
- Qwen3 .mlmodelc load fails with an MLMultiArray shape mismatch (expected [1, 2048], got [1, 512]) [event:61]
- Confirmed in coremltools Python that the spec really is [1, 2048] — then realised the Rust path was loading a different .mlmodelc in the directory [event:66]
- Re-ran with the corrected path; same shape mismatch error. Still stuck. [event:67]

What needs follow-up
- ML eng suggested the conversion script may emit a 512-len variant for the prefill model; will pair tomorrow [event:68]
- Posted end-of-day note in #eng so the team knows the brief-quality eval depends on this unblocking [event:69]

###CITATIONS: [event:61], [event:66], [event:67], [event:68], [event:69]
