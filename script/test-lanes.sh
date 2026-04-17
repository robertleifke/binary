#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/test-lanes.sh <lane>

Lanes:
  fast       forge test --fuzz-runs 20
  sentinels  run 3 sentinel tests at --fuzz-runs 300 -j 1 -vv
  canary     forge test -j 2 --fuzz-runs 300
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

lane="$1"

case "$lane" in
  fast)
    exec forge test --fuzz-runs 20
    ;;
  sentinels)
    /usr/bin/time -p forge test --match-test testFuzz_roundTripSwapReturnsStateNearBaseline --fuzz-runs 300 -j 1 -vv
    /usr/bin/time -p forge test --match-test testFuzz_previewExactOutputOneForZeroReturnsLeastInput --fuzz-runs 300 -j 1 -vv
    /usr/bin/time -p forge test --match-test testFuzz_previewExactOutputZeroForOneReturnsLeastInput --fuzz-runs 300 -j 1 -vv
    ;;
  canary)
    exec forge test -j 2 --fuzz-runs 300
    ;;
  *)
    usage
    exit 1
    ;;
esac
