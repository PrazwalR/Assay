# Security

## Status

**This code is unaudited and has never held value.** It is deployed to Base Sepolia only.
Do not deploy it to a network where it would custody real funds without an independent
review.

## Reporting a vulnerability

Open a private security advisory on the repository rather than a public issue. Include the
affected file and line, the conditions required to reach the code, and the impact. A proof
of concept as a Foundry test is the most useful form.

## Threat model

The hook quotes a fee and takes a surcharge on extreme dislocation. It holds no custody of
swap principal, takes no liquidity permissions, and cannot prevent a liquidity provider from
withdrawing.

The properties the code is built to hold, each covered by tests under `test/`:

- `beforeSwap` and `afterSwap` never revert for a well-formed swap on any pool state. A
  revert on the swap path is a denial of service against every liquidity provider in the
  pool, so every failure degrades to a quoted fee instead.
- Every quoted fee lies within the `[minFeePips, maxFeePips]` range that `feeBounds()`
  advertises, so a router reading it before quoting is not misled.
- The surcharge nets to exactly zero for the hook: `donate` debits it and the returned delta
  repays it, leaving the swapper as the sole funder and the hook holding no balance.
- Only pools whose currencies match the reference oracle's declared pair may attach.
- A reference that is stale, reverting, or out of range degrades to the maximum fee rather
  than to a wrong price presented as correct.

## Analysed and found not exploitable

**Self-dealing on the surcharge.** The surcharge is funded by the swapper and donated
pro-rata to in-range liquidity, so an attacker who is also a liquidity provider recovers
their own share of it. Holding share `s` of in-range liquidity, they pay `S` and receive
`s * S`, a net cost of `(1 - s) * S`. At `s = 1` the surcharge is free — but the attacker is
then the only liquidity provider, so the adverse selection being priced is damage to
themselves and there is no counterparty left to extract from. The mechanism degrades to
economically neutral rather than to exploitable.

**Removing the direction sign.** `Mispricing.signedTicks` flips sign on `zeroForOne`, and
that single flip is the entire per-swap mechanism: without it the hook prices the pool's
drift rather than the order's relationship to it, which is what every volatility-based hook
already does. Mutation testing confirms seven tests fail if it is removed.

**Pool binding.** Disabling either half of the currency check in `_beforeInitialize` fails a
test written specifically for that half. Mutation testing found the `currency0` half
initially unprotected — every existing case also mismatched on `currency1`, masking it — and
`test_Exploit_MismatchedCurrency0AloneIsRefused` now covers it.

## Known limitations

- There is no deviation cap between the reference price and a pool TWAP. A compromised
  Chainlink feed within its staleness window would mis-price fees, bounded by `maxFeePips`.
- `captureShareBps` is calibrated conservatively but its underlying elasticity is bounded
  rather than measured. See `P0-GATE-RESULT.md`.
- The adverse-selection gate does not currently pass. The mechanism is correct; the evidence
  that it improves liquidity-provider outcomes is not yet established. See
  `P0-GATE-RESULT.md`.
- **No independent adversarial review has been completed.** Reentrancy through `donate`, and
  cross-swap fee manipulation via the tick recorded in `afterSwap`, have been reasoned about
  and partially mutation-tested but not audited by a third party.
