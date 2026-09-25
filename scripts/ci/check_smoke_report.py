#!/usr/bin/env python3
"""Validates the JSON report written by `j3nsontop_multitool --smoke-test=<file>`.

    python3 scripts/ci/check_smoke_report.py <report.json> <exit-code> "<label>"

The run passes only if the process exited with 0, the report exists, is valid
JSON and has "ok": true. The report is always printed. On GitHub Actions a
short table is appended to $GITHUB_STEP_SUMMARY. Exits 1 on failure.
"""

import json
import os
import sys


def describe_step(step) -> str:
    if isinstance(step, dict):
        name = step.get("name") or step.get("step") or step.get("id") or "?"
        ok = step.get("ok")
        detail = step.get("detail") or step.get("message") or step.get("error") or ""
        mark = "ok" if ok is True else ("FAILED" if ok is False else "-")
        return f"{mark:6} {name}" + (f" - {detail}" if detail else "")
    return str(step)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    path, exit_code, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    problems = []
    report = None

    if exit_code == 124:
        problems.append("the app did not exit before the timeout")
    elif exit_code != 0:
        problems.append(f"exit code {exit_code}")

    if not os.path.isfile(path):
        problems.append(f"no report written at {path}")
    else:
        with open(path, encoding="utf-8", errors="replace") as handle:
            raw = handle.read()
        print(f"----- smoke report ({label}) -----")
        print(raw)
        print("-" * 40)
        try:
            report = json.loads(raw)
        except ValueError as error:
            problems.append(f"report is not valid JSON ({error})")

    steps = []
    if isinstance(report, dict):
        if report.get("ok") is not True:
            problems.append(f'"ok" is {report.get("ok")!r}, expected true')
        steps = report.get("steps") or []
        for step in steps:
            print("  " + describe_step(step))
    elif report is not None:
        problems.append("report is not a JSON object")

    passed = not problems
    result = f"OK (exit 0, ok=true, {len(steps)} steps)" if passed else "FAILED: " + "; ".join(problems)
    print(f"Smoke test {label}: {result}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as out:
            out.write(f"### Smoke test ({label})\n\n| Result | Steps |\n| --- | ---: |\n")
            out.write(f"| {result.replace('|', '/')} | {len(steps)} |\n\n")
    if not passed and os.environ.get("GITHUB_ACTIONS"):
        print(f"::error title=Smoke test failed ({label})::{'; '.join(problems)}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
