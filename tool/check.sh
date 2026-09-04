#!/bin/bash
# Analyzes and tests the editor.
set -uo pipefail
cd "$(dirname "$0")/.."

failures=0

if flutter analyze > /tmp/orbis_editor_analyze.log 2>&1; then
  echo "  ok    analyze"
else
  echo "  FAIL  analyze"; tail -20 /tmp/orbis_editor_analyze.log; failures=$((failures+1))
fi

if flutter test > /tmp/orbis_editor_test.log 2>&1; then
  summary=$(tr '\r' '\n' < /tmp/orbis_editor_test.log | tail -1 \
    | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[0-9:]* //')
  echo "  ok    $summary"
else
  echo "  FAIL  tests"; tail -25 /tmp/orbis_editor_test.log; failures=$((failures+1))
fi

echo
[ "$failures" -eq 0 ] && echo "everything green" || echo "$failures failing step(s)"
exit "$failures"
