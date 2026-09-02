#!/usr/bin/env python3
"""Emit MCP probes or verify focused-only live-capture responses."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

FOCUSED_TOKEN = "FOCUSED_EVIDENCE_ZEPHYR_9241"
BACKGROUND_TOKEN = "BACKGROUND_SECRET_NEBULA_7713"
CORPUS_BUNDLE_ID = "ai.hippocampus.CaptureOverlapCorpus"


def requests() -> list[dict[str, Any]]:
    return [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "mci_recall",
                "arguments": {"query": FOCUSED_TOKEN, "limit": 10},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "mci_recall",
                "arguments": {"query": BACKGROUND_TOKEN, "limit": 10},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "mci_events_since",
                "arguments": {"ts_us": 0, "limit": 200},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "mci_events_by_app",
                "arguments": {"app_bundle_id": CORPUS_BUNDLE_ID, "limit": 200},
            },
        },
    ]


def emit() -> int:
    for request in requests():
        print(json.dumps(request, separators=(",", ":")))
    return 0


def packed(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def load_responses(path: Path) -> dict[int, dict[str, Any]]:
    responses: dict[int, dict[str, Any]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ValueError(f"could not read MCP responses: {error}") from error

    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            response = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(
                f"MCP response line {line_number} is not JSON: {error}"
            ) from error
        response_id = response.get("id")
        if not isinstance(response_id, int):
            raise ValueError(f"MCP response line {line_number} has no integer id")
        if response_id in responses:
            raise ValueError(f"MCP response id {response_id} appeared twice")
        responses[response_id] = response
    return responses


def result_for(responses: dict[int, dict[str, Any]], response_id: int) -> Any:
    response = responses.get(response_id)
    if response is None:
        raise ValueError(f"MCP response id {response_id} is missing")
    if "error" in response:
        raise ValueError(f"MCP response id {response_id} failed: {response['error']}")
    if "result" not in response:
        raise ValueError(f"MCP response id {response_id} has no result")
    return response["result"]


def verify(path: Path) -> int:
    try:
        responses = load_responses(path)
        if set(responses) != {1, 2, 3, 4, 5}:
            raise ValueError(
                f"expected MCP response ids 1-5, found {sorted(responses)}"
            )

        focused_recall = result_for(responses, 2)
        background_recall = result_for(responses, 3)
        timeline = result_for(responses, 4)
        by_app = result_for(responses, 5)

        if not isinstance(focused_recall, dict) or not isinstance(
            background_recall, dict
        ):
            raise ValueError("focused or background recall result is not an object")

        events = timeline.get("events") if isinstance(timeline, dict) else None
        app_events = by_app.get("events") if isinstance(by_app, dict) else None
        if not isinstance(events, list) or not isinstance(app_events, list):
            raise ValueError("timeline or app-scoped MCP result has no events array")
        if not events:
            raise ValueError("the isolated brain contains no captured events")
        if not app_events:
            raise ValueError(
                "the brain contains no event attributed to the overlap corpus bundle"
            )

        event_text = packed(events)
        app_event_text = packed(app_events)
        focused_recall_text = packed(focused_recall)
        background_recall_text = packed(background_recall)

        if FOCUSED_TOKEN not in event_text or FOCUSED_TOKEN not in app_event_text:
            raise ValueError(
                "the exact focused token is absent from captured corpus events"
            )
        if FOCUSED_TOKEN not in focused_recall_text:
            raise ValueError(
                "the focused token is stored but not returned by the recall query"
            )
        if background_recall.get("outcome") != "nothing_matched" or (
            background_recall.get("reason") != "no_candidates"
        ):
            raise ValueError(
                "the full-text background query found a candidate or could not prove "
                f"candidate absence: {background_recall.get('outcome')}/"
                f"{background_recall.get('reason')}"
            )

        for surface_name, surface in (
            ("timeline", event_text),
            ("corpus app events", app_event_text),
            ("background recall", background_recall_text),
        ):
            if BACKGROUND_TOKEN in surface:
                raise ValueError(
                    f"the background token leaked into the {surface_name} result"
                )

        print(
            json.dumps(
                {
                    "background_token_present": False,
                    "corpus_event_count": len(app_events),
                    "focused_recall_outcome": focused_recall.get("outcome"),
                    "focused_token_present": True,
                    "timeline_event_count": len(events),
                },
                sort_keys=True,
            )
        )
        return 0
    except ValueError as error:
        print(f"memory verification failed: {error}", file=sys.stderr)
        return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("emit", help="write deterministic MCP JSON-RPC probes")
    verify_parser = subparsers.add_parser(
        "verify", help="verify MCP JSON-RPC responses"
    )
    verify_parser.add_argument("--responses", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "emit":
        return emit()
    return verify(args.responses)


if __name__ == "__main__":
    raise SystemExit(main())
