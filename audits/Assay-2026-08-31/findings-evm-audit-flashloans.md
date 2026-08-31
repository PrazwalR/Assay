## Summary

No Critical, High, or Medium severity flash-loan-exploitable vulnerabilities found. Traced the full swap data flow (`_beforeSwap` → `_advanceStateInPlace` → `_afterSwap` → `_donateCeilingOverflow`) against the classic flash-loan-oracle-manipulation pattern; it structurally does not fit:

1. **Fee never derives from the pool's own manipulable price as "the reference."** `state.referenceTick` is set only from `_readReference()` (Chainlink); never from the pool's own tick. The reference side of the fee formula (`ChainlinkReferenceAdapter.referenceSqrtPriceX96()`) calls only `FEED.latestRoundData()` and holds no reference to the PoolManager or any pool — pool activity cannot reach it through any channel.
2. **Deviation cap** (`PoolTwap.withinBound`): the anti-manipulation anchor samples the pool's tick as of a block's *open* — a value fixed before the current transaction began, unreachable by anything a flash-loan-funded transaction does inside itself, since flash loans require same-transaction repayment. Directly asserted by an existing test, `test_Exploit_SameBlockPriceManipulationCannotMoveTheTwapAnchor` (`test/integration/ReferenceDeviationCap.t.sol:114`).
3. **No same-transaction multi-swap advantage.** `_beforeSwap` always reads fresh storage; `_afterSwap` always writes fully advanced state back before returning — bundling two swaps into one router transaction sees identical state transitions to two sequential transactions.
4. **`_donateCeilingOverflow` self-dealing.** Attacker-as-LP self-funds 100% of the donation and recovers at most their pro-rata share — a wash at best net of rounding against them. Third-party JIT-liquidity sniping of the donate (see `M-1` in `findings-evm-audit-defi-amm.md`) is a generic v4 concern, not flash-loan-executable, since it requires capital held across the boundary between the attacker's tx and a separate later victim tx — incompatible with same-tx flash-loan repayment.

No governance, voting, vault/share-price, flash-mint, or auction surfaces exist in `src/`. `IReferencePriceOracle.referenceSqrtPriceX96()` is `external view`, so even a malicious oracle implementation can't use the read as a reentrancy vector (Solidity emits `STATICCALL`).

## [INFO-1] Multi-block EWMA anchor drift is theoretically possible but requires sustained, non-flash, at-risk capital
**Severity**: Info
**Category**: evm-audit-flashloans
**Location**: `src/libraries/PoolTwap.sol` (`update`), `src/AssayHook.sol:330-338` (`_advanceStateInPlace`), `src/config/AssayConfig.sol` (`twapLambdaX32`, default ≈0.99)
**Description**: The EWMA folds in one sample per block containing a swap, weighted ~0.99 toward history — a half-life of ~69 blocks. An attacker willing to hold a real (non-flash) directional position across many consecutive blocks can walk the anchor a meaningful distance over enough blocks. Since the anchor gates whether a fresh Chainlink reading is trusted, this could cause a later legitimate update to be wrongly rejected, or let a bad reading pass if the feed were separately compromised at the same time.
**Proof of Concept**: Not exploitable via flash loan — requires capital left unwound past the transaction boundary. `test_Exploit_SameBlockPriceManipulationCannotMoveTheTwapAnchor` already proves the same-transaction variant leaves the anchor completely unchanged.
**Recommendation**: No change needed for flash-loan resistance. If tighter resistance to the slower multi-block variant is wanted, consider requiring N-of-M consecutive-block confirmation before trusting a previously-rejected reading, or operationally monitoring `ReferenceDeviationCapTripped` for a sustained run.

## [INFO-2] `maxReferenceDeviationTicks` default (20,000 ticks, ≈7.4x price ratio) is a coarse circuit breaker, not a tight manipulation bound
**Severity**: Info
**Category**: evm-audit-flashloans
**Location**: `src/config/AssayConfig.sol` (`maxReferenceDeviationTicks`)
**Description**: 20,000 ticks ≈ 7.39x, deliberately wide to catch only catastrophic feed errors. Not a flash-loan issue — the relevant same-transaction defense is `PoolTwap`'s block-open sampling — but worth the deploying team knowing this parameter is a garbage-data sanity check, not a tight anti-manipulation band. (Same numeric correction as `ORACLE-3` in `findings-evm-audit-oracles.md`.)
**Proof of Concept**: N/A — parameter/design observation.
**Recommendation**: No code change required; document the parameter's intended role in deployment runbooks.

**Files reviewed**: `src/libraries/PoolTwap.sol`, `src/libraries/Mispricing.sol`, `src/libraries/FeeBlend.sol`, `src/AssayHook.sol`, `src/oracle/ChainlinkReferenceAdapter.sol`, `src/config/AssayConfig.sol`, `src/types/PoolState.sol`, `src/interfaces/IReferencePriceOracle.sol`, `src/libraries/Q32x32.sol`, `test/invariant/AssayInvariants.t.sol`, `test/invariant/AssayHandler.sol`, `test/integration/ReferenceDeviationCap.t.sol`, `test/integration/HostileOracle.t.sol`.
