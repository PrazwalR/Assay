## [C-1] Sequencer-downtime staleness window lets frozen reference and pool ticks "agree," suppressing the fee the hook exists to charge
**Severity**: High
**Category**: evm-audit-chain-specific
**Location**: `_advanceStateInPlace()` in `src/AssayHook.sol:320-369`; `referenceSqrtPriceX96()` in `src/oracle/ChainlinkReferenceAdapter.sol:132-149`; reasoning contested is in `SECURITY.md:91-102`

**Note from synthesis**: This is the same root-cause finding as `ORACLE-1` in `findings-evm-audit-oracles.md`, independently derived by a separate specialist agent from the chain-mechanics angle rather than the oracle-mechanics angle. Both agents converged on an identical exploit chain without seeing each other's work — kept as a corroborating second analysis rather than deduplicated away, since the independent convergence is itself signal.

**Description**: `SECURITY.md` accepts "no L2 sequencer uptime check" as safe because "the aggregator cannot be updated while the sequencer is down... the existing staleness check already fires, and `FeeBlend.quote` falls back to `maxFeePips`." That conclusion only holds once the outage has lasted longer than `MAX_AGE_SECONDS` (3600s deployed). For any shorter outage — realistic for OP-Stack sequencer incidents, which have historically run minutes to a couple of hours — the reasoning breaks down because of what freezes *together* on a single-sequencer OP-Stack chain during an outage: no transactions execute at all, so `state.lastTick` cannot move (nothing swaps) AND the Chainlink aggregator's `updatedAt` cannot advance (the update tx can't land). Both signals `_advanceStateInPlace` compares are frozen at their pre-outage values simultaneously. When the sequencer resumes and the first swap lands, `_readReference()` returns the same pre-outage answer (still within `MAX_AGE_SECONDS`), `referenceFresh` reads `true`, and `Mispricing.signedTicks` computes a drift of `0` since both ticks are the same frozen pre-outage values — `FeeBlend.quote` returns the *base* fee, not `maxFeePips`.

An informed trader can trade toward the true (moved) price at the base fee — the exact tier the hook exists to avoid handing them. The reference-deviation cap doesn't help either: `twapTickX32` is an EWMA of `lastTick`, which also never advanced during the outage, so it agrees with the frozen reference too.

**Proof of Concept**: (1) Pool trades normally; `referenceTick ≈ lastTick ≈ T0`. (2) Base's sequencer halts. No blocks, no swaps; Chainlink's `updatedAt` stops advancing, still within the 3600s window. (3) True price moves meaningfully during the outage. (4) Sequencer resumes. (5) An informed trader swaps in the first block, before Chainlink lands a fresh update: quoted `Mispricing.signedTicks(T0, T0, ...) == 0` → `BASE_FEE_PIPS` (500), not `MAX_FEE_PIPS` (10000). (6) `_afterSwap` folds the swap's resulting tick into `lastTick`; the still-stale `referenceTick` now sits close to that new value too. (7) LPs absorb the entire post-outage price-discovery move at the base fee.

**Recommendation**: Track wall-clock time (or block count) since the last successful refresh; if the gap between consecutive refreshes is anomalously large relative to Base's ~2s cadence (e.g. 60+ seconds), force `referenceFresh = false` for that boundary regardless of what the oracle reports — this directly detects "the chain just resumed after a gap," independent of any Chainlink field. Alternatively, tighten `MAX_AGE_SECONDS` well below the timescale of a plausible sequencer incident. Correct `SECURITY.md`'s claim, which is only true once the outage exceeds `MAX_AGE_SECONDS`.

## [I-1] `uint32 lastBlock` wraparound: verified negligible, no action needed
**Severity**: Info
**Category**: evm-audit-chain-specific
**Location**: `PoolState.lastBlock` in `src/types/PoolState.sol:25`; narrowing at `src/AssayHook.sol:241` and `src/AssayHook.sol:330-331`

**Note from synthesis**: Same conclusion as `L-2` in `findings-evm-audit-precision-math.md`, independently confirmed by a second agent — dedupe target for the final report.

**Description**: `uint32` wraps at `4,294,967,295`. At Base's ~2s block time, that's ≈272 years. Not a realistic risk window; even at wraparound the failure mode is benign (defers one reference refresh by one block, once, ~272 years from genesis).
**Proof of Concept**: N/A — not exploitable within any realistic timeframe.
**Recommendation**: None required.

## [L-1] `evm_version = "cancun"` bytecode is a silent portability trap if this source is redeployed to a pre-Cancun L2
**Severity**: Low
**Category**: evm-audit-chain-specific
**Location**: `foundry.toml:11` (`solc_version = "0.8.26"`, `evm_version = "cancun"`)
**Description**: Base Sepolia/mainnet have activated the Cancun-equivalent OP-Stack hardfork (Ecotone), so this is a non-issue for the stated target. `AddressConstants.getPoolManagerAddress` correctly `revert`s on an unrecognized `block.chainid`, so a wrong-network deploy fails loudly. But if this exact compiled artifact were redeployed unmodified to an L2/app-chain that hasn't adopted Cancun opcodes, a `PUSH0`/Cancun opcode appearing only in a specific *runtime* code path lets the contract deploy successfully and only revert with "invalid opcode" the first time a call reaches that branch — harder to notice than a constructor-time failure.
**Proof of Concept**: Not exploitable against Base Sepolia today. Hypothetical non-Cancun target only.
**Recommendation**: Before deploying to any chain other than Base/OP-Stack/Unichain, verify the target's activated hardfork, or build a chain-specific artifact with a lower `evm_version`. Not actionable for the current deployment.

## [I-2] Gas budgets in `docs/gas.md` measure L2 execution gas only, not Base's L1 data-posting fee
**Severity**: Info
**Category**: evm-audit-chain-specific
**Location**: `test/gas/HookOverhead.t.sol` (`_measure`, lines 62-72); `docs/gas.md:9-16`
**Description**: Measured figures come from local Foundry `gasleft()` deltas with no OP-Stack L1-fee simulation. Not a contract defect — nothing in `AssayHook.sol` reads gas price or makes gas-dependent decisions, and the measured figures are trivially far below Base's actual block gas limit. Only actionable point: these numbers are L2-execution-only, not a full real-world transaction cost estimate.
**Proof of Concept**: N/A — not a vulnerability.
**Recommendation**: None required for correctness. Optionally note in `docs/gas.md` that the table is L2-execution-gas only.

**Confirmed non-issues**: no block-count↔elapsed-time conversion anywhere in `src/`; `block.number` on Base/OP-Stack correctly reflects the L2 block (no Arbitrum-style L1-block quirk); no `block.difficulty`/`block.prevrandao`/`blockhash` used as randomness; no non-standard precompiles relied on.
