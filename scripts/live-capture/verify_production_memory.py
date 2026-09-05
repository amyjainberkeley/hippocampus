#!/usr/bin/env python3
"""Read-only installed-brain proof. See production-proof.md for scope/limits."""

import argparse
import json
import os
from pathlib import Path
import pwd
import selectors
import signal
import subprocess
import sys
import time


FOCUSED_TOKEN = "FOCUSED_EVIDENCE_ZEPHYR_9241"
BACKGROUND_TOKEN = "BACKGROUND_SECRET_NEBULA_7713"
AGENT = Path("/Applications/Hippocampus.app/Contents/MacOS/mci-agent")
EVENT_LIMIT = 1000
RECALL_LIMIT = 100
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
TIMEOUT_SECONDS = 90


class ProofError(Exception):
    """Only fixed, content-free reason codes may cross this boundary."""


def positive_integer(value):
    return type(value) is int and 0 < value <= 2**64 - 1


def requests(since_us):
    if not positive_integer(since_us):
        raise ProofError("since_us_must_be_positive_u64")
    probes = [
        ("mci_events_since", {"ts_us": since_us, "limit": EVENT_LIMIT}),
        ("mci_recall", {"query": FOCUSED_TOKEN, "limit": RECALL_LIMIT}),
        ("mci_recall", {"query": BACKGROUND_TOKEN, "limit": RECALL_LIMIT}),
        ("mci_context", {"focus": FOCUSED_TOKEN, "max_tokens": 4096, "max_evidence": 64}),
    ]
    return [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}] + [
        {"jsonrpc": "2.0", "id": index, "method": "tools/call",
         "params": {"name": name, "arguments": arguments}}
        for index, (name, arguments) in enumerate(probes, start=2)
    ]


def parse_responses(wire):
    if len(wire) > MAX_RESPONSE_BYTES:
        raise ProofError("response_size_limit")
    results = {}
    try:
        for line in wire.splitlines():
            if not line.strip():
                continue
            response = json.loads(line)
            if not isinstance(response, dict):
                raise ProofError("invalid_rpc_response")
            response_id = response.get("id")
            if (type(response_id) is not int or response_id not in range(1, 6)
                    or response_id in results or response.get("jsonrpc") != "2.0"):
                raise ProofError("invalid_rpc_response_id")
            if "error" in response:
                raise ProofError("mcp_request_failed")
            result = response.get("result")
            if not isinstance(result, dict) or result.get("isError", False) is not False:
                raise ProofError("mcp_result_failed")
            results[response_id] = result
    except (ValueError, UnicodeError, RecursionError) as from_error:
        raise ProofError("invalid_rpc_json") from from_error
    if set(results) != {1, 2, 3, 4, 5}:
        raise ProofError("missing_rpc_response")
    return results


def rows(value):
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise ProofError("invalid_rows")
    return value


def identity(row):
    event_id, timestamp = row.get("event_id"), row.get("ts_us")
    if not positive_integer(event_id) or not positive_integer(timestamp):
        raise ProofError("invalid_event_identity")
    return event_id, timestamp


def text_field(row, field):
    value = row.get(field)
    if not isinstance(value, str):
        raise ProofError("invalid_evidence_text")
    return value


def contains_background(value):
    # Called only after the evidence timestamp has passed the since boundary.
    if isinstance(value, str):
        return BACKGROUND_TOKEN.casefold() in value.casefold()
    if isinstance(value, dict):
        return any(contains_background(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_background(item) for item in value)
    return False


def validate(results, since_us):
    """Pure validation. Returns no OCR, titles, URLs, server messages, or keys."""
    requests(since_us)
    if set(results) != {1, 2, 3, 4, 5} or any(not isinstance(v, dict) for v in results.values()):
        raise ProofError("invalid_result_set")
    events = rows(results[2].get("events"))
    issues = []
    limitations = [
        "screenshot_reference_api_unavailable",
        "authenticated_screenshot_readback_unverified",
        "background_check_covers_returned_snippets_not_full_ocr_or_pixels",
        "recall_and_context_are_not_server_time_filtered",
        "reads_are_sequential_not_an_atomic_snapshot",
    ]
    capped = len(events) >= EVENT_LIMIT
    if capped:
        issues.append("timeline_limit_reached")
    fresh = {}
    focused = set()
    background = False
    for row in events:
        event_id, timestamp = identity(row)
        if timestamp <= since_us:
            raise ProofError("timeline_outside_since")
        if event_id in fresh:
            raise ProofError("duplicate_timeline_event")
        fresh[event_id] = timestamp
        background |= contains_background(row)
        if FOCUSED_TOKEN in text_field(row, "text_snippet"):
            focused.add(event_id)

    recall_ids = set()
    recall_outcome = results[3].get("outcome")
    for response_id in (3, 4):
        recall = results[response_id]
        outcome = recall.get("outcome")
        if outcome not in ("matched", "nothing_matched", "degraded", "contradicted"):
            raise ProofError("invalid_recall_outcome")
        for group in ("hits", "related_context", "contradicting_context"):
            evidence = rows(recall.get(group))
            if len(evidence) >= RECALL_LIMIT:
                issues.append("recall_limit_reached")
            for row in evidence:
                event_id, timestamp = identity(row)
                if timestamp <= since_us:
                    continue
                background |= contains_background(row)
                eligible = ((outcome == "matched" and group == "hits") or
                            (outcome == "degraded" and group == "related_context"))
                if (response_id == 3 and eligible and event_id in focused
                        and fresh[event_id] == timestamp
                        and FOCUSED_TOKEN in text_field(row, "text_snippet")):
                    recall_ids.add(event_id)
    if recall_outcome == "degraded":
        limitations.append("recall_degraded_observations_only")

    packet = results[5].get("packet")
    if not isinstance(packet, dict):
        raise ProofError("invalid_context_packet")
    citations = {}
    screen_ids = set()
    for citation in rows(packet.get("citations")):
        event_id, timestamp = identity(citation)
        if event_id in citations:
            raise ProofError("duplicate_context_citation")
        citations[event_id] = timestamp
        if timestamp <= since_us:
            continue
        background |= contains_background(citation)
        if (event_id in focused and fresh[event_id] == timestamp
                and citation.get("source_kind") == "screen_ocr"):
            screen_ids.add(event_id)
    context_ids = set()
    for section in rows(packet.get("sections")):
        for item in rows(section.get("items")):
            links = item.get("citation_event_ids")
            if not isinstance(links, list) or any(not positive_integer(i) for i in links):
                raise ProofError("invalid_context_links")
            if not links or any(i not in citations for i in links):
                issues.append("uncited_context_item_not_inspected")
                continue
            # Do not inspect old or mixed-age item text. The API has no since filter.
            if any(citations[i] <= since_us for i in links):
                if any(citations[i] > since_us for i in links):
                    issues.append("mixed_age_context_item_not_inspected")
                continue
            background |= contains_background(item)
            if (section.get("status") in ("observed", "grounded")
                    and FOCUSED_TOKEN in text_field(item, "text")):
                context_ids.update(screen_ids.intersection(links))

    if background:
        issues.append("background_token_detected")
    checks = {
        "fresh_focused_event": bool(focused),
        "screen_ocr": bool(screen_ids),
        "recall_evidence": bool(recall_ids),
        "context_citation": bool(context_ids),
        "same_event_across_surfaces": bool(recall_ids & context_ids),
        "background_token_not_observed": not background and not capped,
    }
    issues.extend(name + "_not_proven" for name, passed in checks.items() if not passed)
    return {
        "status": "failed" if background else "incomplete",
        "source_recall_context_verified": all(checks.values()) and not issues,
        "since_us": since_us,
        "checks": checks,
        "recall_outcome": recall_outcome,
        "fixture_events": [{"event_id": i, "ts_us": fresh[i]} for i in sorted(focused)],
        "screenshot_reference": "unsupported",
        "authenticated_screenshot_readback": "unsupported",
        "issues": sorted(set(issues)),
        "limitations": limitations,
    }


def production_environment(home):
    # No inherited raw keys, dev flags, DB overrides, plugins, or network credentials.
    return {
        "HOME": str(home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "MCI_DB_KEYCHAIN_SERVICE": "ai.hippocampus.brain",
        "MCI_DB_KEYCHAIN_ACCOUNT": "database-key-v1",
        "MCI_DB_KEYCHAIN_STORAGE_MODEL": "file-keychain-acl-v1",
    }


def query_installed_brain(since_us):
    payload = b"".join(json.dumps(r).encode() + b"\n" for r in requests(since_us))
    if sys.platform != "darwin" or os.getuid() == 0:
        raise ProofError("requires_normal_macos_user")
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    if not AGENT.is_file() or not os.access(AGENT, os.X_OK):
        raise ProofError("installed_agent_unavailable")
    if not (home / "Library/Application Support/MCI/mci.sqlite").is_file():
        raise ProofError("normal_user_brain_unavailable")
    # mcp-serve uses LiveBrainReader::open_readonly and the normal Keychain path.
    # Stderr is discarded: native error messages may contain user paths or content.
    with subprocess.Popen([str(AGENT), "mcp-serve"], cwd=home,
                          env=production_environment(home), stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          start_new_session=True) as process:
        try:
            process.stdin.write(payload)
            process.stdin.close()
            output = bytearray()
            deadline = time.monotonic() + TIMEOUT_SECONDS
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ProofError("agent_timeout")
                    for key, _ in selector.select(remaining):
                        chunk = os.read(key.fd, 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            break
                        output.extend(chunk)
                        if len(output) > MAX_RESPONSE_BYTES:
                            raise ProofError("response_size_limit")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProofError("agent_timeout")
            if process.wait(timeout=remaining) != 0:
                raise ProofError("installed_agent_failed")
            return parse_responses(output)
        finally:
            if process.poll() is None:
                # Only terminate the child process group this invocation created.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since-us", type=int, required=True,
                        help="positive Unix microseconds immediately before the fixture capture")
    args = parser.parse_args()
    try:
        report = validate(query_installed_brain(args.since_us), args.since_us)
    except ProofError as error:
        report = {"status": "error", "reason": str(error)}
    except (OSError, KeyError, ValueError, RecursionError, subprocess.SubprocessError):
        report = {"status": "error", "reason": "local_probe_failed"}
    except KeyboardInterrupt:
        report = {"status": "error", "reason": "interrupted"}
    print(json.dumps(report, sort_keys=True))
    # Full screenshot proof is deliberately unavailable, even when OCR checks pass.
    return 1 if report["status"] in ("failed", "error") else 2


if __name__ == "__main__":
    sys.exit(main())
