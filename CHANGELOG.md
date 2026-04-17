# Changelog

## v0.2.0 - 2026-04-17

### Inventory & Anchor Risk Controls

- Added inventory-aware skew control (`inventorySkewWad`).
- Added per-trade notional caps (`maxTradeSizeWad`).
- Introduced stale-anchor protection:
  - max age enforcement (`maxAnchorAge`)
  - emergency pause toggle (`emergencyPauseOnStaleAnchor`)
  - emergency spread widening (`emergencyWidenWad`)
- Wired all guards into quote and execution paths.
- Expanded test coverage for risk controls.
- Added Base Sepolia smoke and minimal cycle scripts.
- Established runtime test lanes baseline.

### Rationale

This is a minor release because execution behavior, risk profile, and production safety materially changed without a breaking interface change.
