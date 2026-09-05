"""Pure fixtures only: never opens a brain, starts an agent, or reads keys."""

import copy
import json
from pathlib import Path
import unittest

import verify_production_memory as proof


SINCE = 1_000


def fixture():
    row = {"event_id": 7, "ts_us": 1_001, "text_snippet": proof.FOCUSED_TOKEN}
    recall = {"outcome": "matched", "hits": [copy.deepcopy(row)],
              "related_context": [], "contradicting_context": []}
    packet = {
        "outcome": "observations_only",
        "citations": [{"event_id": 7, "ts_us": 1_001, "source_kind": "screen_ocr"}],
        "sections": [{"status": "observed", "items": [
            {"text": proof.FOCUSED_TOKEN, "citation_event_ids": [7]}
        ]}],
    }
    return {1: {}, 2: {"events": [row]}, 3: recall,
            4: {"outcome": "nothing_matched", "hits": [],
                "related_context": [], "contradicting_context": []},
            5: {"packet": packet}}


class ValidationTests(unittest.TestCase):
    def test_ocr_recall_and_context_are_not_screenshot_proof(self):
        report = proof.validate(fixture(), SINCE)
        self.assertEqual(report["status"], "incomplete")
        self.assertTrue(report["source_recall_context_verified"])
        self.assertTrue(all(report["checks"].values()))
        self.assertEqual(report["fixture_events"], [{"event_id": 7, "ts_us": 1001}])
        self.assertEqual(report["screenshot_reference"], "unsupported")
        self.assertEqual(report["authenticated_screenshot_readback"], "unsupported")

    def test_no_memory_is_plainly_incomplete(self):
        data = fixture()
        data[2]["events"] = []
        report = proof.validate(data, SINCE)
        self.assertFalse(report["checks"]["fresh_focused_event"])
        self.assertEqual(report["fixture_events"], [])

    def test_since_is_strict_and_old_recall_is_not_inspected(self):
        data = fixture()
        data[3]["hits"] = [{"event_id": 9, "ts_us": SINCE,
                            "text_snippet": proof.BACKGROUND_TOKEN}]
        report = proof.validate(data, SINCE)
        self.assertFalse(report["checks"]["recall_evidence"])
        self.assertTrue(report["checks"]["background_token_not_observed"])
        data[2]["events"][0]["ts_us"] = SINCE
        with self.assertRaisesRegex(proof.ProofError, "timeline_outside_since"):
            proof.validate(data, SINCE)

    def test_background_in_each_fresh_surface_fails_without_printing_it(self):
        for surface in ("timeline", "recall", "background_recall", "context"):
            with self.subTest(surface=surface):
                data = fixture()
                if surface == "context":
                    data[5]["packet"]["sections"][0]["items"][0]["text"] += proof.BACKGROUND_TOKEN
                elif surface == "background_recall":
                    data[4]["related_context"] = [{"event_id": 8, "ts_us": 1002,
                                                  "text_snippet": proof.BACKGROUND_TOKEN}]
                else:
                    row = data[2]["events"][0] if surface == "timeline" else data[3]["hits"][0]
                    row["text_snippet"] += proof.BACKGROUND_TOKEN
                report = proof.validate(data, SINCE)
                self.assertEqual(report["status"], "failed")
                self.assertNotIn(proof.BACKGROUND_TOKEN, json.dumps(report))

    def test_wrong_source_and_unlinked_context_do_not_prove_capture(self):
        for change in ("source", "link", "timestamp", "echo"):
            data = fixture()
            packet = data[5]["packet"]
            if change == "source":
                packet["citations"][0]["source_kind"] = "import"
            elif change == "link":
                packet["sections"][0]["items"][0]["citation_event_ids"] = [99]
            elif change == "timestamp":
                packet["citations"][0]["ts_us"] = 1002
            else:
                packet["focus"] = proof.FOCUSED_TOKEN
                packet["sections"][0]["items"][0]["text"] = "unrelated"
            self.assertFalse(proof.validate(data, SINCE)["checks"]["context_citation"])

    def test_recall_must_match_event_timestamp_and_actual_text(self):
        for field, value in (("ts_us", 1002), ("event_id", 99), ("text_snippet", "other")):
            data = fixture()
            data[3]["hits"][0][field] = value
            self.assertFalse(proof.validate(data, SINCE)["checks"]["recall_evidence"])

    def test_degraded_recall_is_labeled_observed_not_matched(self):
        data = fixture()
        data[3]["outcome"] = "degraded"
        data[3]["related_context"] = data[3].pop("hits")
        data[3]["hits"] = []
        report = proof.validate(data, SINCE)
        self.assertTrue(report["checks"]["recall_evidence"])
        self.assertEqual(report["recall_outcome"], "degraded")
        self.assertIn("recall_degraded_observations_only", report["limitations"])

    def test_cap_never_claims_exhaustive_absence(self):
        data = fixture()
        data[2]["events"] = [{"event_id": i + 1, "ts_us": 1001 + i,
                              "text_snippet": ""} for i in range(proof.EVENT_LIMIT)]
        report = proof.validate(data, SINCE)
        self.assertIn("timeline_limit_reached", report["issues"])
        self.assertFalse(report["checks"]["background_token_not_observed"])

    def test_unrelated_content_is_never_in_report(self):
        data = fixture()
        data[2]["events"].append({"event_id": 8, "ts_us": 1002,
                                  "text_snippet": "PRIVATE unrelated OCR",
                                  "window_title": "PRIVATE title", "url": "PRIVATE URL"})
        self.assertNotIn("PRIVATE", json.dumps(proof.validate(data, SINCE)))

    def test_duplicate_and_malformed_rows_fail_closed(self):
        data = fixture()
        data[2]["events"] *= 2
        with self.assertRaises(proof.ProofError):
            proof.validate(data, SINCE)
        for invalid in (True, -1, "1001", None):
            data = fixture()
            data[2]["events"][0]["ts_us"] = invalid
            with self.assertRaises(proof.ProofError):
                proof.validate(data, SINCE)

    def test_protocol_errors_do_not_disclose_server_errors(self):
        wire = json.dumps({"jsonrpc": "2.0", "id": 1,
                           "error": {"message": "PRIVATE OCR"}}).encode()
        with self.assertRaises(proof.ProofError) as error:
            proof.parse_responses(wire)
        self.assertNotIn("PRIVATE", str(error.exception))

    def test_requests_are_bounded_read_only_and_focus_is_fixed(self):
        requests = proof.requests(SINCE)
        self.assertEqual(requests[1]["params"]["arguments"],
                         {"ts_us": SINCE, "limit": proof.EVENT_LIMIT})
        self.assertEqual([r["params"]["name"] for r in requests[1:]],
                         ["mci_events_since", "mci_recall", "mci_recall", "mci_context"])
        self.assertEqual(requests[-1]["params"]["arguments"]["focus"], proof.FOCUSED_TOKEN)
        for invalid in (0, -1, True, "1000"):
            with self.assertRaises(proof.ProofError):
                proof.requests(invalid)

    def test_protocol_round_trip_and_rejected_shapes(self):
        frames = [{"jsonrpc": "2.0", "id": i, "result": result}
                  for i, result in fixture().items()]

        def encode(values):
            return b"\n".join(json.dumps(value).encode() for value in values)

        self.assertEqual(proof.parse_responses(encode(frames)), fixture())
        for invalid in (frames[:-1], frames + [frames[0]], [True],
                        [{"jsonrpc": "2.0", "id": True, "result": {}}],
                        [{"jsonrpc": "2.0", "id": 1, "result": {"isError": True}}]):
            with self.assertRaises(proof.ProofError):
                proof.parse_responses(encode(invalid))

    def test_old_and_mixed_context_text_is_not_inspected(self):
        data = fixture()
        packet = data[5]["packet"]
        packet["citations"].append({"event_id": 8, "ts_us": SINCE,
                                    "source_kind": "screen_ocr"})
        item = {"text": proof.BACKGROUND_TOKEN, "citation_event_ids": [8]}
        packet["sections"][0]["items"].append(item)
        report = proof.validate(data, SINCE)
        self.assertTrue(report["source_recall_context_verified"])
        item["citation_event_ids"] = [7, 8]
        report = proof.validate(data, SINCE)
        self.assertFalse(report["source_recall_context_verified"])
        self.assertIn("mixed_age_context_item_not_inspected", report["issues"])
        self.assertTrue(report["checks"]["background_token_not_observed"])

    def test_different_events_cannot_jointly_prove_the_three_surfaces(self):
        data = fixture()
        data[2]["events"].append({"event_id": 8, "ts_us": 1002,
                                  "text_snippet": proof.FOCUSED_TOKEN})
        data[3]["hits"][0].update(event_id=8, ts_us=1002)
        report = proof.validate(data, SINCE)
        self.assertTrue(report["checks"]["recall_evidence"])
        self.assertTrue(report["checks"]["context_citation"])
        self.assertFalse(report["source_recall_context_verified"])

    def test_environment_contains_only_normal_public_references(self):
        home = Path("/Users/fixture space; $(not-a-command)")
        env = proof.production_environment(home)
        self.assertEqual(env["HOME"], str(home))
        self.assertEqual(set(env), {"HOME", "PATH", "MCI_DB_KEYCHAIN_SERVICE",
                                   "MCI_DB_KEYCHAIN_ACCOUNT", "MCI_DB_KEYCHAIN_STORAGE_MODEL"})
        self.assertEqual(env["MCI_DB_KEYCHAIN_STORAGE_MODEL"], "file-keychain-acl-v1")


if __name__ == "__main__":
    unittest.main()
