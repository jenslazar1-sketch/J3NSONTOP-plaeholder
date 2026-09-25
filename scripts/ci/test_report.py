#!/usr/bin/env python3
"""Summarises a `flutter test --file-reporter json:<file>` report.

    python3 scripts/ci/test_report.py <report.json> "<title>"

Prints the counts and, on GitHub Actions, appends a table to
$GITHUB_STEP_SUMMARY. Always exits 0: the `flutter test` exit code decides
whether the job fails; this script only reports.
"""

import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    path, title = sys.argv[1], sys.argv[2]
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")

    if not os.path.isfile(path):
        message = f"No test report was written ({path}); the test run did not start or crashed early."
        print(message)
        if summary_path:
            with open(summary_path, "a", encoding="utf-8") as out:
                out.write(f"### {title}\n\n{message}\n\n")
        return 0

    names = {}
    passed = failed = skipped = 0
    failures = []
    overall = None
    with open(path, encoding="utf-8", errors="replace") as report:
        for line in report:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            kind = event.get("type")
            if kind == "testStart":
                test = event.get("test", {})
                names[test.get("id")] = test.get("name", "?")
            elif kind == "testDone":
                if event.get("hidden"):
                    continue  # suite loading pseudo-tests
                if event.get("skipped"):
                    skipped += 1
                elif event.get("result") == "success":
                    passed += 1
                else:
                    failed += 1
                    failures.append(names.get(event.get("testID"), "?"))
            elif kind == "done":
                overall = event.get("success")

    total = passed + failed + skipped
    status = "passed" if overall and failed == 0 else "FAILED"
    print(f"{title}: {status} - total {total}, passed {passed}, failed {failed}, skipped {skipped}")
    for name in failures:
        print(f"  failed: {name}")

    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as out:
            out.write(f"### {title}: {status}\n\n")
            out.write("| Total | Passed | Failed | Skipped |\n| ---: | ---: | ---: | ---: |\n")
            out.write(f"| {total} | {passed} | {failed} | {skipped} |\n\n")
            if failures:
                out.write("Failed tests:\n\n")
                for name in failures[:30]:
                    safe_name = name.replace("`", "'")
                    out.write(f"- `{safe_name}`\n")
                if len(failures) > 30:
                    out.write(f"- ... and {len(failures) - 30} more\n")
                out.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
