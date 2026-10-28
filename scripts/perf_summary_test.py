"""Summarize a small recorded trace."""
import io
from contextlib import redirect_stdout
import unittest

from perf_summary import print_comparison, print_summary, summarize

TRACE = {
    "metadata": {"liloVersion": "0.6.0", "durationSeconds": 12, "tabs": 3},
    "traceEvents": [
        {"ph": "M", "name": "process_name", "pid": 1, "tid": 0, "ts": 0, "args": {"name": "Lilo"}},
        {"ph": "M", "name": "process_name", "pid": 2, "tid": 0, "ts": 0, "args": {"name": "tab 1"}},
        {"ph": "X", "cat": "bridge", "name": "handle", "pid": 1, "tid": 1, "ts": 1000, "dur": 300000},
        {"ph": "X", "cat": "bridge", "name": "handle", "pid": 1, "tid": 1, "ts": 900000, "dur": 2000},
        {"ph": "X", "cat": "main", "name": "hang", "pid": 1, "tid": 1, "ts": 50000, "dur": 150000},
        {"ph": "i", "cat": "frames", "name": "drop", "pid": 1, "tid": 1, "ts": 60000, "s": "t", "args": {"detail": "4"}},
        {"ph": "C", "cat": "process", "name": "cpu %", "pid": 2, "tid": 0, "ts": 500000, "args": {"value": 10}},
        {"ph": "C", "cat": "process", "name": "cpu %", "pid": 2, "tid": 0, "ts": 1000000, "args": {"value": 30}},
        {"ph": "C", "cat": "process", "name": "footprint MB", "pid": 2, "tid": 0, "ts": 1000000, "args": {"value": 210.5}},
    ],
}


class PerfSummaryTests(unittest.TestCase):
    def test_summarizes_intervals_hangs_and_processes(self):
        summary = summarize(TRACE)
        self.assertEqual(summary["intervals"]["bridge/handle"]["count"], 2)
        self.assertEqual(summary["intervals"]["bridge/handle"]["max"], 300.0)
        self.assertEqual(summary["hangs"], [{"atMs": 50.0, "durationMs": 150.0, "during": ["bridge/handle"]}])
        self.assertEqual(summary["droppedFrames"], 4)
        self.assertEqual(summary["processes"]["tab 1"]["cpuAvg"], 20)
        self.assertEqual(summary["processes"]["tab 1"]["footprintEndMB"], 210.5)

    def test_prints_summary_and_comparison(self):
        output = io.StringIO()
        with redirect_stdout(output):
            print_summary(summarize(TRACE))
            print_comparison(summarize(TRACE), summarize(TRACE))
        self.assertIn("bridge/handle", output.getvalue())
        self.assertIn("Main-thread hangs: 1, 150 ms", output.getvalue())


if __name__ == "__main__":
    unittest.main()
