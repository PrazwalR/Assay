# ETHSKILLS Audit — Pass 2: Oracles and Denial of Service

**Methodology:** `evm-audit-master` routing. Checklists loaded this pass:
`evm-audit-oracles`, `evm-audit-dos`. The `evm-audit-defi-amm` and
`evm-audit-precision-math` checklists were deliberately **not** reloaded — pass 1 anchored on
them, and re-running would re-confirm rather than look fresh.

**Scope:** `src/oracle/`, `src/AssayHook.sol` callback paths, `script/DeployOracle.s.sol`.
Context: `docs/ASSAY-CONTEXT.md` §0 authoritative.

**Live data used:** Base Sepolia ETH/USD proxy `0x4aDC…7cb1`, aggregator
`0xa24A68DD788e1D7eb4CA517765CFb2b7e217e7a3`, queried during this audit.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 2 |

---

## [M-1] A feed with unexpected decimals deploys silently and produces a reference wrong by orders of magnitude

**Severity:** Medium
**Category:** evm-audit-oracles (item 10 — decimal precision variation)
**Location:** `script/DeployOracle.s.sol:33`, `src/oracle/ChainlinkReferenceAdapter.sol:29`

**Description.** `PRICE_NUMERATOR` encodes `10^(token1Decimals - token0Decimals + feedDecimals)`
and is supplied as a raw constructor argument. The adapter never calls `feed.decimals()`, and
the deploy script's only validation is:

```solidity
require(fresh, "DeployOracle: feed did not return a usable price");
```

`fresh` is true for any positive, recent answer — including one whose decimals do not match
the numerator. The check gives false assurance precisely where the mistake is most likely.

**Proof of Concept.** Deployed numerator is `1e20`, correct for the 8-decimal ETH/USD feed
(verified: `decimals() == 8`). Pointing the same numerator at a feed with different decimals:

| feed decimals | decoded reference | true price |
|---|---|---|
| 8 (correct) | $2,466.00 | $2,466 |
| 18 | **$24,660,000,000,000.00** | $2,466 |
| 6 | **$24.66** | $2,466 |

An 18-decimal feed yields a reference 10^10 too high. The deploy succeeds, `require(fresh)`
passes, and every subsequent swap is priced against a reference that is not the price of
anything. Because the reference tick would sit far outside any plausible pool tick, the drift
clamps at `MAX_MISPRICING_TICKS` and the pool quotes `minFeePips` or `maxFeePips` permanently
depending on direction — a pool that charges 1% to everyone in one direction and 0.01% in the
other, with no error anywhere.

**Why Medium, not higher.** Requires a deployer mistake; no third party can trigger it. But it
is silent, permanent (the adapter is immutable), and the existing check actively suggests the
configuration was validated.

**Recommendation.** Verify at construction rather than trusting the caller — the adapter knows
the decimals it needs:

```solidity
interface IAggregatorV3 { function decimals() external view returns (uint8); }

// in the constructor, alongside the existing checks
uint256 expected = 10 ** (uint256(token1Decimals) - uint256(token0Decimals) + feed.decimals());
if (priceNumerator != expected) {
    revert ChainlinkReferenceAdapter__PriceNumeratorMismatch(priceNumerator, expected);
}
```

This requires passing the two token decimals, which the deploy script can read from the token
contracts — making the whole scaling derivable rather than asserted.

---

## [L-1] No L2 sequencer uptime check, on a chain where that is the standard mitigation

**Severity:** Low
**Category:** evm-audit-oracles (items 8, 9 — sequencer uptime, grace period)
**Location:** `src/oracle/ChainlinkReferenceAdapter.sol:53`

**Description.** The hook is deployed to Base, an OP-stack L2. The checklist's standard
requirement is to read Chainlink's sequencer uptime feed and enforce a grace period after a
restart. Nothing in `src/` references a sequencer feed — verified by grep.

**Why the usual consequence does not apply here.** The classic failure is a lending protocol
liquidating at a stale price on restart. This system degrades in the opposite direction. The
Chainlink aggregator on Base is itself an L2 contract, so during sequencer downtime it cannot
be updated and `updatedAt` stops advancing. On restart, the existing staleness check fires,
`fresh` becomes false, and `FeeBlend.quote` returns `maxFeePips`. Nobody receives a cheap
swap; there is no profitable action for an attacker, and the pool over-charges rather than
under-charges.

**The residual consequence is real but small:** between sequencer restart and the first feed
update, legitimate swaps pay the ceiling. That is a degraded-economics window, not a loss.

**Recommendation.** Adding the sequencer feed would introduce a second external call on the
refresh path, in a system whose gas budget is already the binding constraint, to detect a
condition the staleness check already handles conservatively. **I recommend documenting the
reasoning rather than adding the check** — but it belongs in `SECURITY.md` as an explicit
decision, not as an unexamined omission, which is what it is today.

---

## [L-2] `startedAt` is not validated

**Severity:** Low
**Category:** evm-audit-oracles (item 4 — started round validation)
**Location:** `src/oracle/ChainlinkReferenceAdapter.sol:57`

```solidity
if (answer <= 0 || updatedAt == 0) return (0, false);
```

**Description.** The checklist calls for `startedAt > 0` to confirm a round actually began.
The adapter checks `updatedAt == 0` instead, which catches the same "round never completed"
condition for OCR feeds, where both fields are written together. On a legacy aggregator mid-
round it is possible for `startedAt` to be set while `updatedAt` is not — already covered —
but not the reverse.

**Assessment.** No exploit path found. The existing check is the stronger of the two for the
feed family actually in use. Reported because the checklist item is unaddressed and silence
would be worse than the note.

**Recommendation.** Adding `startedAt == 0` to the same guard costs one comparison and closes
the item completely. The `try/catch` already makes any additional revert path harmless.

---

## [I-1] Min/max circuit breakers are unchecked, but non-binding on the deployed feed

**Severity:** Informational
**Category:** evm-audit-oracles (item 5 — min/max circuit breakers)

**Description.** When an aggregator's true price moves outside `[minAnswer, maxAnswer]`, it
reports the bound rather than the price. The adapter would accept that as a valid, fresh
reading and price fees against it.

**Measured on the live aggregator:**

| bound | raw | in USD |
|---|---|---|
| `minAnswer` | 1 | $0.00000001 |
| `maxAnswer` | 95780971304118053647396689196894323976171195136475135 | ~$9.6e44 |

Both are non-binding by ten or more orders of magnitude — these are the `int192` sentinel
defaults, not real circuit breakers. ETH would have to reach one hundredth of a microcent for
the floor to engage.

**Assessment.** Not exploitable on this feed. Worth knowing that the check is absent if the
hook is ever pointed at a feed with genuine bounds, which some older aggregators have.

---

## [I-2] `try/catch` around the oracle can be forced into its catch branch by gas metering

**Severity:** Informational
**Category:** evm-audit-dos (try/catch gas insufficiency, beirao G-18)
**Location:** `src/AssayHook.sol` `_readReference()`

**Description.** EIP-150 forwards 63/64 of remaining gas to a sub-call. A caller who meters
gas precisely can make the oracle sub-call run out while leaving the outer frame enough to
continue, forcing the `catch` branch. `fresh` becomes false and `referenceFresh` is written to
storage, so **every subsequent swap in that block quotes `maxFeePips`** until the next block's
refresh succeeds.

**Why this is Informational, not a finding.** The griefing direction is upward. The attacker
pays the ceiling themselves on the swap that triggers it, and every other swap in the block
over-pays rather than under-pays — there is no position from which this is profitable. It
harms other users mildly and costs the attacker a swap at 1%, which is a bad trade.

**Noted for completeness because** the same mechanism in a system that degraded *downward*
would be a genuine vulnerability. The safety here comes entirely from the choice to fail
conservatively, which is why that choice is load-bearing rather than cosmetic.

---

## Verified clean

**`evm-audit-oracles`**

| # | Item | Result |
|---|---|---|
| 1 | `updatedAt` staleness | Checked against configurable `MAX_AGE_SECONDS`; `HostileOracle.t.sol` and `ReferenceOracle.t.sol` cover the boundary at exactly the bound and one second past |
| 2 | Chain-specific heartbeat | `MAX_AGE_SECONDS` is a constructor parameter, not hardcoded; documented in `.env.example` as needing to exceed the feed's heartbeat |
| 3 | `answeredInRound` | Deliberately discarded, with the reasoning in NatSpec: the idiom applied to legacy aggregators and is not meaningful for OCR feeds. Triaged in `docs/audit/M1/slither.md` |
| 6 | Negative price | `answer <= 0` rejected before any cast; tested |
| 7 | Zero price | Same guard; tested |
| 11 | Deprecated feed addresses | Immutable by deliberate design (context §6) — recalibration means redeploying |
| 12 | Denomination mismatch | ETH/USD against a USDC/WETH pool; USDC is the intended USD proxy and the decimal scaling accounts for it. Verified numerically against the live feed to 0.000000% |
| 13 | Single oracle dependency | No fallback, by design. Failure degrades to `maxFeePips` rather than reverting — context §6 |
| 14 | Update frequency mismatch | Reference refreshed at most once per block against a feed with a much longer heartbeat; the staleness bound is set above the heartbeat, not below |

**`evm-audit-dos`**

| Item | Result |
|---|---|
| ETH receiver with reverting fallback | Not applicable — the hook never sends ETH |
| Token transfer blocklist DoS | Not applicable — the hook never transfers tokens; `donate` moves value inside the PoolManager's ledger |
| Zero-amount transfer reverts | Guarded: `if (amount == 0) return 0` before any donate, tested by `test_DustSwap_OwesASurchargeThatRoundsToNothing` |
| Insufficient gas forwarding | No fixed-gas `.call{gas:}` anywhere in `src/` |
| External calls inside loops | No loops in `src/` |
| Returndata bombing | The only untrusted external call is the oracle, which is immutable and deployer-set. A malicious oracle implies a malicious deployer, who has strictly more direct attacks available |
| Unbounded state growth | No arrays. State is one packed slot per pool, 88 of 256 bits |

---

## Not verified, and why

- **Behaviour during an actual Base sequencer outage.** Reasoned about from the architecture
  (the aggregator is an L2 contract and cannot update while the sequencer is down), not
  observed. The conclusion that staleness catches it follows from that premise.
- **Feeds with binding min/max bounds.** The deployed feed's are sentinel defaults; the
  adapter's behaviour against a genuinely bounded feed is untested.
- **Gas-metered forcing of the catch branch.** Reasoned from EIP-150, not constructed as a
  test. Building it would require precise gas accounting against the live oracle cost.
