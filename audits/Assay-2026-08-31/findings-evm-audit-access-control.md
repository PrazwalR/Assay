## Independent verification of the "no admin" claim

Re-ran and extended the prior review's grep across `src/` — zero matches, confirmed independently. Every piece of state in `AssayHook.sol` besides `_poolState` is `private immutable`, assigned once in the constructor after `AssayConfigLib.validate(config)`, with no setter anywhere. `ChainlinkReferenceAdapter.sol`'s state is likewise all `public immutable`. `AssayConfigLib.validate()` is `pure`, invoked once synchronously before any immutable is written. Deploy scripts grant no owner/multisig/role to anyone. **Conclusion: the "no owner, no admin key, no pause, no upgradeability" claim checks out** — no privileged caller exists anywhere in `AssayHook.sol`, `ChainlinkReferenceAdapter.sol`, or `AssayConfig.sol`, direct or indirect.

## `BaseHook`/`onlyPoolManager` gating — verified, not assumed

Read the actual resolved implementation at `lib/uniswap-hooks/src/base/BaseHook.sol`. Every external `IHooks` entry point carries `onlyPoolManager`, dispatching to an `internal virtual _xxx`. `AssayHook` overrides only the internal variants, never re-declares the external wrappers — the gate is not bypassable. Cross-checked `PoolManager.updateDynamicLPFee`, which independently requires `msg.sender == address(key.hooks)`. **Confirmed correctly and completely inherited; no bypass found.**

## Findings

### [AC-1] No admin, pause, or upgrade path exists to respond to a live incident in deployed pools
**Severity**: Low
**Category**: evm-audit-access-control
**Location**: `src/AssayHook.sol` (whole-contract design), `src/oracle/ChainlinkReferenceAdapter.sol` (whole-contract design)
**Description**: `AssayHook` and `ChainlinkReferenceAdapter` are fully immutable with no owner, pauser, or upgrade mechanism. This eliminates admin-key-drains-the-protocol risk entirely, but if the oracle integration, deviation cap, or fee-blend math is later found to have an exploitable edge case, there is no lever — no pause, no per-pool kill switch, no way to redirect `REFERENCE_ORACLE`, no way to block new pools from attaching — to stop it while a fix is prepared. Pool creation against this hook is permissionless and hook attachment is permanent. Meaningfully mitigated versus a typical AMM: `getHookPermissions()` sets all liquidity-related hooks `false` — LPs can always exit via `PoolManager.modifyLiquidity` regardless of hook state, and the hook never holds a custodial balance. So the residual risk is degraded/exploitable fee pricing persisting until affected LPs independently notice and withdraw, not direct custody loss.
**Proof of Concept**: Not exploitable as a standalone bug — an architectural absence, not a bypassable check.
**Recommendation**: Legitimate design choice for a maximally-decentralized/immutable hook; flagging for explicit sign-off rather than prescribing a change. If a circuit breaker is wanted, the minimum-centralization option would be a narrowly-scoped, revocable/time-limited `guardian` address that can only force `referenceFresh = false` for a specific `poolId`, never touching custody, `REFERENCE_ORACLE`, or config bounds. Absent that, state the tradeoff explicitly in deployer/LP-facing docs.

### [AC-2] `ChainlinkReferenceAdapter.FEED` is immutable, but the aggregator it points to may not be
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: `src/oracle/ChainlinkReferenceAdapter.sol:34,106` (`FEED` immutable), `referenceSqrtPriceX96()` lines 132-149
**Description**: `FEED` is `immutable` and cannot be changed by Assay's own contracts. However, production Chainlink feeds are commonly deployed behind an `AggregatorProxy` whose Chainlink-controlled admin can repoint the proxy to a different underlying aggregator at the same address. Standard third-party trust assumption, not a defect in Assay's code.
**Proof of Concept**: Not exploitable by Assay's contracts or deployer.
**Recommendation**: Document which specific feed (proxy vs. raw aggregator) is used per deployment and what governs it.

### [AC-3] `onlyPoolManager` gating and immutable-only configuration confirmed correct
**Severity**: Info
**Category**: evm-audit-access-control
**Location**: `lib/uniswap-hooks/src/base/BaseHook.sol` (inherited by `src/AssayHook.sol`)
**Description**: Recorded per review instructions. No missing-modifier, privilege-escalation, two-step-ownership, role-management, or initializer findings — the standard checklist categories don't apply to a contract with no privileged role at all.
**Proof of Concept**: N/A — confirmatory finding.
**Recommendation**: None required.

**Files reviewed**: `src/AssayHook.sol`, `src/oracle/ChainlinkReferenceAdapter.sol`, `src/config/AssayConfig.sol`, `src/interfaces/IAssayErrors.sol`, `src/interfaces/IAssayEvents.sol`, `src/interfaces/IReferencePriceOracle.sol`, `lib/uniswap-hooks/src/base/BaseHook.sol`, `lib/uniswap-hooks/lib/v4-core/src/PoolManager.sol`, `script/DeployAssay.s.sol`, `script/DeployOracle.s.sol`, `test/unit/AssayHookPermissions.t.sol`.
