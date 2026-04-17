## Full-suite control
- Command: `forge test -j 2 --fuzz-runs 300`
- Baseline: `328.36s`
- Date: `2026-04-08`

## Guardrails
- `>380s` investigate
- `>450s` stop and isolate pathological path

## Sentinel tests
- `forge test --match-test testFuzz_roundTripSwapReturnsStateNearBaseline --fuzz-runs 300 -j 1 -vv` -> `156.72s` (2026-04-08)
- `forge test --match-test testFuzz_previewExactOutputOneForZeroReturnsLeastInput --fuzz-runs 300 -j 1 -vv` -> `154.51s` (2026-04-08)
- `forge test --match-test testFuzz_previewExactOutputZeroForOneReturnsLeastInput --fuzz-runs 300 -j 1 -vv` -> `154.31s` (2026-04-08)

## Trigger rule
Rerun sentinel tests before merge when changes:
- add loops
- add stateful/repeated sequences
- touch Gaussian / pricing math

## Lane split
- Dev loop: `forge test --fuzz-runs 20`
- Pre-push signal: run sentinel tests above
- Final gate: full-suite control command above

## Uniform runner
- Script: `bash script/test-lanes.sh <fast|sentinels|canary>`
- Package scripts:
  - `bun run test:lane:fast`
  - `bun run test:lane:sentinels`
  - `bun run test:lane:canary`
