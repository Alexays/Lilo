#!/usr/bin/env python3
"""Lists the tests that failed and then passed on a retry, as Markdown for a CI job summary.

Takes Xcode result bundles (.xcresult) and Playwright JSON reports, skipping those a failed build never wrote
or left unreadable; prints nothing when no test needed a retry. Each one is also a warning annotation on
stderr, which the run's checks list shows.
"""
import json
import os
import re
import subprocess
import sys


def xcode_retried(bundle):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"::notice::{bundle} holds no test results: {result.stderr.strip()[:300]}", file=sys.stderr)
        return []
    tree = json.loads(result.stdout)
    retried = []

    def walk(node):
        runs = [child for child in node.get("children", []) if child.get("nodeType") == "Repetition"]
        if node.get("nodeType") == "Test Case" and node.get("result") != "Failed" \
                and any(run.get("result") == "Failed" for run in runs):
            failures = [
                message.get("name", "") for run in runs if run.get("result") == "Failed"
                for message in run.get("children", []) if message.get("nodeType") == "Failure Message"
            ]
            retried.append((node.get("nodeIdentifier") or node.get("name"), failures[0] if failures else ""))
        for child in node.get("children", []):
            walk(child)

    for node in tree.get("testNodes", []):
        walk(node)
    return retried


def playwright_retried(report_path):
    with open(report_path, encoding="utf-8") as report:
        report = json.load(report)
    retried = []

    def walk(suite, titles):
        for spec in suite.get("specs", []):
            for test in spec.get("tests", []):
                if test.get("status") != "flaky":
                    continue
                errors = [result.get("error", {}).get("message", "") for result in test.get("results", []) if result.get("status") != "passed"]
                retried.append((" > ".join(titles + [spec["title"]]), errors[0] if errors else ""))
        for child in suite.get("suites", []):
            walk(child, titles + [child["title"]])

    for suite in report.get("suites", []):
        walk(suite, [suite["title"]])
    return retried


def main(paths):
    retried = []
    for path in filter(os.path.exists, paths):
        retried += xcode_retried(path) if path.rstrip("/").endswith(".xcresult") else playwright_retried(path)
    if not retried:
        return
    print("### Tests that passed only on a retry\n")
    print("They did not fail the run, but they are flaky: please fix them.\n")
    for name, failure in retried:
        # The first line of the failure, without ANSI colors or backticks that would break the Markdown.
        first = re.sub(r"\x1b\[[0-9;]*m", "", failure).split("\n", 1)[0].replace("`", "'")
        print(f"- `{name}`" + (f": {first[:300]}" if first else ""))
        print(f"::warning title=Flaky test::{name} passed only on a retry", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
