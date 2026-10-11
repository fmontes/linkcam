#!/usr/bin/env bash
set -euo pipefail

CLI="${1:-./linkcam}"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/linkcam-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

"$CLI" help | grep -q "linkcam status"
"$CLI" version | grep -q "linkcam 0.2.0"

if "$CLI" pan '12oops' >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    echo "invalid angle unexpectedly succeeded" >&2
    exit 1
fi
grep -q "invalid pan value" "$TEST_TMP/err"

if "$CLI" zoom 50 >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    echo "ambiguous zoom unexpectedly succeeded" >&2
    exit 1
fi
grep -q "invalid zoom" "$TEST_TMP/err"

if "$CLI" ai definitely-not-valid >"$TEST_TMP/out" 2>"$TEST_TMP/err"; then
    echo "invalid AI action unexpectedly succeeded" >&2
    exit 1
fi
grep -q "usage: linkcam ai" "$TEST_TMP/err"

echo "CLI argument tests passed"
