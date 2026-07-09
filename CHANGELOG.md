# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Move package (`hunchbook_launchpad`, `coin_template`) and the TypeScript SDK
(`mentara` on npm) are versioned together in this repo for now; the protocol
version will split from the SDK version once the Move package has its own
release cadence (Meteora does the same: program `0.2.0`, SDK `1.5.x`).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

### Breaking Changes

## [0.1.0] — 2026-07-08

### Added

- `move/hunchbook_launchpad`: the on-chain protocol — `config` (immutable
  launch-config template, curve segments, fee scheduler, quote type, fee
  waterfall), `pool` (bonding-curve `VirtualPool`, buy/sell, permissionless
  fee claims for protocol/partner/creator), `amm` (post-graduation
  constant-product pool, same fixed-destination claim model), `math` (Q64.64
  sqrt-price curve math, mirrors Meteora DBC's CLMM formulas).
- `move/coin_template`: patchable coin bytecode template for programmatic,
  no-compiler-at-runtime coin publishing.
- `src/`: framework-agnostic, deployment-agnostic TypeScript SDK —
  `math` (curve quoting, fee scheduler, AMM quoting, curve solver), `read`
  (pool/config state), `tx` (buy/sell/claim/migrate/create-config/create-pool
  builders), `coin` (template patch + publish), `client` (`MentaraClient`
  with Meteora-style namespaces: `state`, `pool`, `partner`, `creator`,
  `migration`), plus standalone functions for callers who don't want the
  client wrapper.
- 26 Move unit tests covering curve math exactness, fee-scheduler decay
  (linear + exponential), the 20/40/40 fee waterfall on both venues,
  graduation partial-fills/refund/halt, and migration running exactly once.
- Verified end to end on Sui testnet (real transactions, not just unit
  tests): first-buy fee exemption, fee waterfall to the unit, graduation at
  the exact threshold, migration, and 1% AMM fee.

[0.1.0]: https://github.com/keshav2800/mentara/commit/47638e0e69f84c7c3dd6699c586f1138f6f885f2
