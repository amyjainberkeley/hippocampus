#!/usr/bin/env python3
"""Build the deterministic synthetic agent-handoff-v1 corpus."""

from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


CAPABILITIES = [
    "semantic_relevance",
    "temporal_supersession",
    "contradiction",
    "duplicate_ocr",
    "exact_provenance",
    "abstention",
    "handoff_utility",
]


def source(
    session_id: str,
    date: str,
    app_bundle_id: str,
    window_title: str,
    url: str,
    text: str,
) -> dict[str, str]:
    return {
        "session_id": session_id,
        "date": date,
        "app_bundle_id": app_bundle_id,
        "window_title": window_title,
        "url": url,
        "text": text,
    }


def task(
    question_id: str,
    capability: str,
    question: str,
    sources: list[dict[str, str]],
    answer_session_ids: list[str],
    *,
    required_facts: list[str],
    required_session_ids: list[str] | None = None,
    forbidden_session_ids: list[str] | None = None,
    contradiction_session_ids: list[str] | None = None,
    duplicate_session_ids: list[str] | None = None,
    max_duplicate_citations: int = 0,
    unanswerable: bool = False,
    max_tokens: int = 384,
    max_evidence: int = 6,
) -> dict[str, Any]:
    item: dict[str, Any] = {
        "question_id": question_id,
        "question_type": capability,
        "capability": capability,
        "question": question,
        "question_date": "2026/09/02 (Wed) 18:00",
        "answer_session_ids": answer_session_ids,
        "haystack_dates": [value["date"] for value in sources],
        "haystack_session_ids": [value["session_id"] for value in sources],
        "haystack_app_ids": [value["app_bundle_id"] for value in sources],
        "haystack_window_titles": [value["window_title"] for value in sources],
        "haystack_urls": [value["url"] for value in sources],
        "haystack_sessions": [
            [{"role": "assistant", "content": value["text"]}] for value in sources
        ],
        "tags": [capability, "agent_handoff", *sorted({value["app_bundle_id"] for value in sources})],
        "handoff_expectation": {
            "required_facts": required_facts,
            "required_session_ids": required_session_ids or [],
            "forbidden_session_ids": forbidden_session_ids or [],
            "contradiction_session_ids": contradiction_session_ids or [],
            "duplicate_session_ids": duplicate_session_ids or [],
            "max_duplicate_citations": max_duplicate_citations,
            "expect_abstention": unanswerable,
            "max_tokens": max_tokens,
            "max_evidence": max_evidence,
        },
    }
    if unanswerable:
        item["unanswerable"] = True
    return item


def semantic_tasks() -> list[dict[str, Any]]:
    specs = [
        (
            "semantic-embeddings-advisory",
            "Where did we decide that semantic similarity cannot establish a fact?",
            "browser://adr/0010",
            "Embedding scores are retrieval hints only; a source-backed verifier must establish support.",
            "retrieval hints only",
        ),
        (
            "semantic-release-upload-blocker",
            "What is preventing the Mac release from being uploaded?",
            "linear://HIP-311",
            "HIP-311 is blocked because the release machine has no Developer ID Application signing identity.",
            "no Developer ID Application signing identity",
        ),
        (
            "semantic-global-recall-hotkey",
            "Which change made memory search available before the Recall window existed?",
            "github://hippocampus/pull/517",
            "PR 517 moved the global Shift Command Space hotkey into the always-running menu-bar shell.",
            "moved the global Shift Command Space hotkey",
        ),
        (
            "semantic-bounded-agent-context",
            "How do we keep an AI handoff from swallowing the whole activity history?",
            "file:///docs/agent-context.md",
            "The mci_context handoff compiles a bounded cited packet for the current focus instead of dumping history.",
            "bounded cited packet",
        ),
        (
            "semantic-missing-embedder",
            "What should an agent see when the local semantic model cannot load?",
            "terminal://zsh/embedder-health",
            "When Arctic Embed S is unavailable, recall reports embeddings_unavailable and exposes lexical related context as degraded.",
            "embeddings_unavailable",
        ),
        (
            "semantic-pre-pixel-privacy",
            "What prevents a stale window identity from admitting sensitive pixels?",
            "file:///docs/privacy/focus-gate.md",
            "The focus-generation gate binds each frame to the current Accessibility window snapshot before pixel admission.",
            "focus-generation gate",
        ),
    ]
    out = []
    for index, (task_id, question, answer_id, answer_text, fact) in enumerate(specs):
        sources = [
            source(
                f"slack://distractor/semantic-{index}",
                "2026/09/01 (Tue) 09:00",
                "com.tinyspeck.slackmacgap",
                f"Unrelated planning thread {index + 1}",
                f"slack://distractor/semantic-{index}",
                "The design review moved to Friday and the notes need a final formatting pass.",
            ),
            source(
                answer_id,
                "2026/09/02 (Wed) 11:00",
                "com.apple.Safari" if answer_id.startswith("browser") else "com.microsoft.VSCode",
                f"Agent memory decision {index + 1}",
                answer_id,
                answer_text,
            ),
            source(
                f"linear://distractor/semantic-{index}",
                "2026/09/02 (Wed) 13:00",
                "com.linear",
                f"UI polish issue {index + 1}",
                f"linear://distractor/semantic-{index}",
                "The settings sidebar needs an alignment pass before screenshots are refreshed.",
            ),
        ]
        out.append(
            task(
                task_id,
                "semantic_relevance",
                question,
                sources,
                [answer_id],
                required_facts=[fact],
                required_session_ids=[answer_id],
            )
        )
    return out


def temporal_tasks() -> list[dict[str, Any]]:
    specs = [
        ("temporal-owner", "Who owns HIP-204 now?", "Martin", "Priya", "linear://HIP-204/old", "linear://HIP-204/current"),
        ("temporal-model-path", "What is the current installed embedding model path?", "~/Models/ArcticEmbedS_INT8.mlmodelc", "/Applications/Hippocampus.app/Contents/Resources/Models/ArcticEmbedS_INT8.mlmodelc", "file:///old-model-path", "file:///current-model-path"),
        ("temporal-launch-date", "What is the current launch date for Atlas?", "September 8", "September 15", "slack://atlas/launch-old", "linear://ATLAS-90/current"),
        ("temporal-benchmark-count", "How many tasks are in agent-handoff-v1 now?", "24 tasks", "36 tasks", "file:///benchmark-count-old", "file:///benchmark-count-current"),
        ("temporal-signing-team", "Which Apple team identifier should the release use now?", "OLDTEAM42", "NEWTEAM73", "file:///signing-team-old", "file:///signing-team-current"),
        ("temporal-capture-state", "What happens to capture after onboarding is completed now?", "capture remains disabled", "capture is enabled and the verified helper topology starts", "github://capture/old", "github://capture/current"),
    ]
    out = []
    for index, (task_id, question, old_value, current_value, old_id, current_id) in enumerate(specs):
        sources = [
            source(old_id, "2026/09/01 (Tue) 09:00", "com.microsoft.VSCode", f"Previous state {index + 1}", old_id, f"Previous plan: {old_value}."),
            source(current_id, "2026/09/02 (Wed) 14:00", "com.linear", f"Current state {index + 1}", current_id, f"Current decision: {current_value}. This supersedes the previous plan."),
            source(f"terminal://distractor/temporal-{index}", "2026/09/02 (Wed) 15:00", "com.apple.Terminal", f"Unrelated test run {index + 1}", "", "The focused package tests completed without changing the decision."),
        ]
        out.append(
            task(
                task_id,
                "temporal_supersession",
                question,
                sources,
                [current_id],
                required_facts=[current_value],
                required_session_ids=[current_id],
                forbidden_session_ids=[old_id],
            )
        )
    return out


def contradiction_tasks() -> list[dict[str, Any]]:
    specs = [
        ("contradiction-retention", "What conflict exists about screenshot retention?", "screenshots are retained for 30 days", "screenshots are retained for 90 days"),
        ("contradiction-cloud", "What conflict exists about cloud uploads?", "raw captures never leave the Mac", "raw captures are uploaded for remote indexing"),
        ("contradiction-pr-state", "What conflict exists about PR 522?", "PR 522 is merged", "PR 522 is blocked on review"),
        ("contradiction-customer-date", "What conflicting delivery promise was recorded for Meridian?", "SSO ships by the end of Q3", "SSO ships in Q4"),
        ("contradiction-password-manager", "What conflict exists about password-manager capture?", "password-manager windows are always blocked", "password-manager windows may be captured when focused"),
    ]
    out = []
    for index, (task_id, question, left_fact, right_fact) in enumerate(specs):
        left_id = f"slack://conflict/{index}/left"
        right_id = f"github://conflict/{index}/right"
        sources = [
            source(left_id, "2026/09/02 (Wed) 10:00", "com.tinyspeck.slackmacgap", f"Conflict note {index + 1} A", left_id, left_fact + "."),
            source(right_id, "2026/09/02 (Wed) 10:05", "com.github.GitHubClient", f"Conflict note {index + 1} B", right_id, right_fact + "."),
            source(f"file:///conflict/{index}/background", "2026/09/01 (Tue) 08:00", "com.apple.TextEdit", f"Background {index + 1}", "", "The release checklist requires conflicts to remain visible until resolved."),
        ]
        out.append(
            task(
                task_id,
                "contradiction",
                question,
                sources,
                [left_id, right_id],
                required_facts=[left_fact, right_fact],
                required_session_ids=[left_id, right_id],
                contradiction_session_ids=[left_id, right_id],
            )
        )
    return out


def duplicate_tasks() -> list[dict[str, Any]]:
    specs = [
        ("duplicate-build-status", "What happened to the release build?", "The notarized release build completed successfully."),
        ("duplicate-test-status", "What happened in the capture privacy test?", "The capture privacy test blocked the password window."),
        ("duplicate-owner-status", "Who accepted the memory benchmark follow-up?", "Priya accepted the memory benchmark follow-up."),
        ("duplicate-deploy-status", "What happened to the documentation deploy?", "The documentation deploy reached production."),
        ("duplicate-sync-status", "What happened to the MCP synchronization?", "The MCP synchronization imported twelve approved resources."),
    ]
    out = []
    for index, (task_id, question, fact) in enumerate(specs):
        duplicate_ids = [f"screen://duplicate/{index}/{copy}" for copy in range(1, 4)]
        sources = [
            source(session_id, f"2026/09/02 (Wed) 12:0{copy}", "com.apple.Terminal", f"Repeated status {index + 1}", f"screen://duplicate/{index}", fact)
            for copy, session_id in enumerate(duplicate_ids, start=1)
        ]
        sources.append(source(f"slack://duplicate/{index}/distractor", "2026/09/02 (Wed) 11:00", "com.tinyspeck.slackmacgap", f"Unrelated status {index + 1}", "", "The product review agenda has three unrelated design topics."))
        out.append(
            task(
                task_id,
                "duplicate_ocr",
                question,
                sources,
                duplicate_ids,
                required_facts=[fact],
                duplicate_session_ids=duplicate_ids,
                max_duplicate_citations=1,
            )
        )
    return out


def provenance_tasks() -> list[dict[str, Any]]:
    specs = [
        ("provenance-pr", "Which source says the context packet is bounded?", "github://hippocampus/pull/531", "com.github.GitHubClient", "PR 531 bounded agent handoff", "PR 531 says mci_context emits a bounded packet with canonical citations."),
        ("provenance-linear", "Which source assigns the signing blocker?", "linear://HIP-311/comment-7", "com.linear", "HIP-311 signing blocker", "HIP-311 comment 7 assigns the signing blocker to the release owner."),
        ("provenance-browser", "Which source describes the local-only storage promise?", "https://hippocampus.local/privacy", "com.apple.Safari", "Hippocampus privacy architecture", "The privacy architecture says raw memory remains in the local encrypted brain."),
        ("provenance-terminal", "Which source records the benchmark command?", "terminal://zsh/agent-handoff-run", "com.apple.Terminal", "Terminal agent handoff benchmark", "Command: scripts/eval/agent-handoff/run.sh --out result.json"),
        ("provenance-file", "Which source defines trusted answer qualification?", "file:///docs/eval/agent-handoff-v1.md", "com.microsoft.VSCode", "agent-handoff-v1.md", "The benchmark document states trusted_answer_qualified remains false until a qualified verifier exists."),
    ]
    out = []
    for index, (task_id, question, answer_id, app, title, fact) in enumerate(specs):
        sources = [
            source(answer_id, "2026/09/02 (Wed) 09:30", app, title, answer_id, fact),
            source(f"slack://provenance/{index}/distractor", "2026/09/02 (Wed) 09:35", "com.tinyspeck.slackmacgap", f"Nearby source {index + 1}", "", "A nearby thread mentions the same project but does not contain the requested record."),
        ]
        out.append(
            task(
                task_id,
                "exact_provenance",
                question,
                sources,
                [answer_id],
                required_facts=[fact],
                required_session_ids=[answer_id],
            )
        )
    return out


def abstention_tasks() -> list[dict[str, Any]]:
    specs = [
        ("abstain-approver", "Who approved PR 531?", "PR 531 describes bounded context packets but does not name an approver."),
        ("abstain-due-date", "What due date was assigned to HIP-311?", "HIP-311 records a signing blocker and an owner but no schedule."),
        ("abstain-duration", "How long did the capture privacy test take?", "The capture privacy test passed after blocking the password window."),
        ("abstain-count", "How many customers requested the MCP handoff?", "Customer interviews discussed the MCP handoff without recording a total."),
        ("abstain-owner", "Who owns the documentation deployment?", "The documentation deployment reached production without an owner field."),
    ]
    out = []
    for index, (task_id, question, evidence) in enumerate(specs):
        sources = [
            source(f"github://abstain/{index}/topic", "2026/09/02 (Wed) 10:00", "com.github.GitHubClient", f"Related but incomplete record {index + 1}", f"github://abstain/{index}", evidence),
            source(f"slack://abstain/{index}/nearby", "2026/09/02 (Wed) 10:05", "com.tinyspeck.slackmacgap", f"Nearby discussion {index + 1}", "", "The team discussed rollout details that do not answer the requested field."),
        ]
        out.append(
            task(
                task_id,
                "abstention",
                question,
                sources,
                [],
                required_facts=[],
                unanswerable=True,
            )
        )
    return out


def handoff_tasks() -> list[dict[str, Any]]:
    specs = [
        (
            "handoff-release-brief",
            "Prepare context for finishing the Mac release",
            [
                ("linear://release/blocker", "The release is blocked by the missing Developer ID Application identity."),
                ("github://release/hotkey", "The menu-bar shell now owns the global recall hotkey."),
                ("file:///release/checklist", "The release checklist still requires notarization and a real capture soak."),
            ],
            ["missing Developer ID Application identity", "global recall hotkey", "notarization and a real capture soak"],
        ),
        (
            "handoff-memory-quality",
            "Prepare context for improving memory quality",
            [
                ("file:///memory/retrieval", "Hybrid retrieval reaches all expected sources at rank three in the small work-memory fixture."),
                ("linear://memory/verifier", "Trusted semantic support remains blocked because no verifier model is validation-qualified."),
                ("github://memory/provenance", "Every context item must retain its canonical event citation."),
            ],
            ["rank three", "no verifier model is validation-qualified", "canonical event citation"],
        ),
        (
            "handoff-privacy-review",
            "Prepare context for the capture privacy review",
            [
                ("file:///privacy/cascade", "The suppression cascade fails closed when Accessibility window identity is unavailable."),
                ("github://privacy/generation", "The focus generation race gate rejects frames captured against stale window state."),
                ("linear://privacy/permission", "Accessibility and Screen Recording are required onboarding permissions."),
            ],
            ["fails closed", "rejects frames captured against stale window state", "required onboarding permissions"],
        ),
        (
            "handoff-agent-integration",
            "Prepare context for connecting Claude and Codex",
            [
                ("file:///agents/key-boundary", "Client registration stores a Keychain reference and never writes database key bytes."),
                ("github://agents/mcp", "The local MCP server exposes read-only recall and mci_context tools."),
                ("terminal://agents/status", "Connection status must distinguish installed clients from skipped clients."),
            ],
            ["never writes database key bytes", "read-only recall and mci_context tools", "distinguish installed clients from skipped clients"],
        ),
    ]
    out = []
    for index, (task_id, question, records, facts) in enumerate(specs):
        sources = [
            source(session_id, f"2026/09/02 (Wed) 13:0{position}", "com.microsoft.VSCode", f"Handoff source {index + 1}.{position}", session_id, text)
            for position, (session_id, text) in enumerate(records, start=1)
        ]
        answer_ids = [record[0] for record in records]
        out.append(
            task(
                task_id,
                "handoff_utility",
                question,
                sources,
                answer_ids,
                required_facts=facts,
                required_session_ids=answer_ids,
                max_tokens=256,
                max_evidence=5,
            )
        )
    return out


def build() -> dict[str, Any]:
    instances = [
        *semantic_tasks(),
        *temporal_tasks(),
        *contradiction_tasks(),
        *duplicate_tasks(),
        *provenance_tasks(),
        *abstention_tasks(),
        *handoff_tasks(),
    ]
    return {
        "dataset_id": "synthetic-agent-handoff-v1",
        "description": "Synthetic acceptance corpus for evidence-backed local agent handoff. It measures retrieval and packet utility, not answer generation.",
        "task_count": len(instances),
        "capabilities": CAPABILITIES,
        "trusted_answer_qualified": False,
        "instances": instances,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path(__file__).with_name("agent-handoff-v1.json"))
    args = parser.parse_args()
    args.out.write_text(json.dumps(build(), indent=2, sort_keys=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
