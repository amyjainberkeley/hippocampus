"""The worker reads a screen and sends nothing off this Mac.

ONNX Runtime's official build carries Microsoft's telemetry client, on by
default (reports/e2e, finding S1). worker.py turns it off before ONNX Runtime
starts. These tests run the worker under their own no-network sandbox, with
an environment that leaves out the launcher's ORT_DISABLE_TELEMETRY, and
read the unified log with the storage audit's parser
(scripts/lib/ocr_offline.py): no CFNetwork task, no connection attempt, no
sandbox refusal, and no device ID or session file left behind. Each takes
about 20 seconds, because the telemetry client's first upload comes some
nine seconds after the worker starts.
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parents[1] / 'scripts' / 'lib'))

import ocr_offline  # noqa: E402

LIVE = sys.platform == 'darwin' and Path(ocr_offline.SANDBOX_EXEC).exists() and Path('/usr/bin/log').exists()


@unittest.skipUnless(LIVE, 'needs macOS: sandbox-exec and the unified log')
class OfflineWorkerTests(unittest.TestCase):
    def assert_sends_nothing(self, command):
        result = ocr_offline.probe(command, [ocr_offline.bitmap_of_text(ocr_offline.EXPECTED)])
        self.assertEqual(ocr_offline.problems(result, ocr_offline.EXPECTED), [])

    def test_the_source_worker_sends_nothing(self):
        self.assert_sends_nothing([sys.executable, str(ROOT / 'worker.py'), '--serve'])

    def test_the_frozen_worker_sends_nothing(self):
        worker = ROOT / 'dist' / 'hippocampus-ocr' / 'hippocampus-ocr'
        if not worker.is_file():
            self.skipTest('no frozen worker in tools/ocr/dist')
        self.assert_sends_nothing([str(worker), '--serve'])


class OfflineCheckTests(unittest.TestCase):
    """The check itself: it names what a worker that phones home does."""

    def test_a_worker_that_reaches_for_the_network_fails(self):
        result = {'log_readable': True, 'ready': {'version': 1, 'ready': True},
                  'replies': [{'version': 1, 'lines': [{'text': text} for text in ocr_offline.EXPECTED]}],
                  'exit': 0, 'tasks': 3, 'connections': 3, 'requests': 0, 'pid': 7,
                  'refusals': ['network-outbound /private/var/run/mDNSResponder'],
                  'left_behind': ['home/Library/Application Support/Microsoft/DeveloperTools/.onnxruntime/deviceid',
                                  'cwd/:memory:.ses'],
                  'stderr': ''}
        found = ocr_offline.problems(result, ocr_offline.EXPECTED)
        self.assertEqual(len(found), 3)
        self.assertIn('3 CFNetwork task(s)', found[0])
        self.assertIn('mDNSResponder', found[1])
        self.assertIn(':memory:.ses', found[2])

    def test_a_worker_that_reads_nothing_fails(self):
        result = {'log_readable': True, 'ready': {'version': 1, 'ready': True},
                  'replies': [{'version': 1, 'lines': []}], 'exit': 0, 'tasks': 0, 'connections': 0,
                  'requests': 0, 'pid': 7, 'refusals': [], 'left_behind': [], 'stderr': ''}
        self.assertIn('did not read', ocr_offline.problems(result, ocr_offline.EXPECTED)[0])

    def test_the_log_parser_counts_tasks_and_connections_for_the_pid_only(self):
        entries = [
            {'processID': 7, 'processImagePath': '/x/hippocampus-ocr',
             'eventMessage': 'Task <A>.<1> resuming, timeouts(60.0, 604800.0) qos(0x15)'},
            {'processID': 7, 'processImagePath': '/x/hippocampus-ocr',
             'eventMessage': 'Connection 0: creating secure tcp or quic connection'},
            {'processID': 7, 'processImagePath': '/x/hippocampus-ocr',
             'eventMessage': 'Task <A>.<1> sent request, body S 42443'},
            {'processID': 7, 'processImagePath': '/x/other',
             'eventMessage': 'Task <B>.<1> resuming, timeouts(60.0, 604800.0)'},
            {'processID': 8, 'processImagePath': '/x/hippocampus-ocr',
             'eventMessage': 'Task <C>.<1> resuming, timeouts(60.0, 604800.0)'},
        ]
        activity = ocr_offline.storage_audit.network_activity(entries, {7: {'hippocampus-ocr'}})
        self.assertEqual(list(activity), [(7, 'hippocampus-ocr')])
        found = activity[(7, 'hippocampus-ocr')]
        self.assertEqual((found['tasks'], found['connections'], found['requests'], found['bytes']), (1, 1, 1, 42443))


if __name__ == '__main__':
    unittest.main()
