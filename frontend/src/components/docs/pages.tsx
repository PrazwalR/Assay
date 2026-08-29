import Link from "next/link";

import {
  CAP_BINDS_AT_TICKS,
  CONTRACTS,
  DEPLOYED,
  FLOOR_BINDS_AT_TICKS,
  GAS,
  PERMISSION_MASK,
  explorerAddress,
  shortAddress,
} from "@/lib/protocol/config";
import { Callout, Code, CodeBlock, DataTable, H2, Lede, P, Ul } from "@/components/docs/prose";

/**
 * Doc page bodies.
 *
 * Written as components rather than MDX because every page carries figures that must come from
 * `lib/protocol/config.ts` — the deployed parameters, the derived binding points, the measured
 * gas. A prose file with those numbers typed in would go stale the first time a parameter
 * changed, which is exactly the failure mode the docs are supposed to guard against.
 */

function Introduction() {
  return (
    <>
      <Lede>
        Assay is a Uniswap v4 hook that prices adverse selection per swap rather than per pool.
        It is a pricing mechanism, not an access-control mechanism: it never blocks, never
        censors, and never takes custody of swap principal.
      </Lede>

      <H2 id="the-problem">The problem</H2>
      <P>
        An automated market maker makes a standing offer at a price that only updates when
        someone trades against it. When the external market moves, the pool is stale, and an
        arbitrageur takes the difference. That bleed has a name in the literature —
        loss-versus-rebalancing — and it is the dominant cost of providing liquidity.
      </P>
      <P>
        Dynamic-fee hooks respond by raising the fee when volatility rises. But volatility is a
        property of the <em>block</em>, not of the order. Within one block, a retail swap and a
        top-of-block arbitrage pay the same rate — though one is the liquidity provider&apos;s
        entire revenue and the other is their entire loss.
      </P>
      <P>
        Assay prices the <em>order</em>. It measures how far the pool sits from a cached
        reference price, signs that distance by the direction the swap trades, and charges a
        share of what the swap actually captures. Two swaps in the same block, against the same
        drift, in opposite directions, are quoted differently. That single sign flip is the
        whole mechanism.
      </P>

      <H2 id="deployment">Deployment</H2>
      <DataTable
        head={["What", "Where"]}
        rows={[
          [
            "Hook",
            <a key="hook" href={explorerAddress(CONTRACTS.hook)} target="_blank" rel="noreferrer">
              {shortAddress(CONTRACTS.hook)} ↗
            </a>,
          ],
          [
            "Oracle adapter",
            <a
              key="oracle"
              href={explorerAddress(CONTRACTS.oracleAdapter)}
              target="_blank"
              rel="noreferrer"
            >
              {shortAddress(CONTRACTS.oracleAdapter)} ↗
            </a>,
          ],
          ["Chain", "Base Sepolia · 84532"],
          ["Permission mask", <Code key="mask">{PERMISSION_MASK}</Code>],
        ]}
      />
      <Callout tone="warm" title="No pool is initialised">
        The hook and its oracle are deployed and responding — the reference price shown on the
        overview is a live contract read. But no pool has been created against the hook, so
        there is no trading history, no liquidity, and no <Code>SwapAssayed</Code> events. Every
        pool-derived figure on this site is a labelled fixture.
      </Callout>
    </>
  );
}

function Mechanism() {
  return (
    <>
      <Lede>
        The fee is the base fee plus a share of the drift the swap captures, clamped to an
        advertised range. There is no model to fit and no coefficients to trust — one parameter,
        applied to one measurement.
      </Lede>

      <H2 id="deployed-parameters">Deployed parameters</H2>
      <DataTable
        head={["Parameter", "Value", "Meaning"]}
        rows={[
          ["baseFeePips", DEPLOYED.baseFeePips.toLocaleString("en-US"), "Quoted when the pool sits at its reference"],
          ["minFeePips", DEPLOYED.minFeePips.toLocaleString("en-US"), "Floor on any quote"],
          ["maxFeePips", DEPLOYED.maxFeePips.toLocaleString("en-US"), "Ceiling on any quote"],
          [
            "captureShareBps",
            DEPLOYED.captureShareBps.toLocaleString("en-US"),
            "Share of captured drift charged as fee",
          ],
        ]}
      />
      <P>
        A pip is a hundredth of a basis point, so <Code>maxFeePips</Code> of{" "}
        {DEPLOYED.maxFeePips.toLocaleString("en-US")} is 1.00%. One tick is one basis point of
        price, which makes a tick of drift worth 100 pips before the share is applied — so at{" "}
        {DEPLOYED.captureShareBps.toLocaleString("en-US")} bps each tick adds{" "}
        {(100 * DEPLOYED.captureShareBps) / 10_000} pips. The ceiling therefore binds at{" "}
        {CAP_BINDS_AT_TICKS.toLocaleString("en-US")} ticks and the floor at{" "}
        {FLOOR_BINDS_AT_TICKS} ticks.
      </P>
      <CodeBlock>{`quote = clamp(
  baseFeePips + ceil(drift × 100 × captureShareBps / 10000),
  minFeePips,
  maxFeePips
)`}</CodeBlock>
      <Callout title="The rounding is deliberate">
        The surcharge rounds toward positive infinity, not toward zero. Solidity&apos;s signed
        division truncates toward zero, which on the capturing side would quote a fee{" "}
        <em>below</em> its exact value — the liquidity-adverse direction. This was a real audit
        finding, and it is fixed in the contract, mirrored in this interface, and pinned by a
        shared test fixture that the Solidity, the Python calibration and this frontend all
        assert against.
      </Callout>

      <H2 id="why-1000-bps">Why {DEPLOYED.captureShareBps.toLocaleString("en-US")} bps</H2>
      <P>
        Charging the full drift would deter the arbitrage entirely and leave the pool stale —
        which loses the uninformed flow that is the liquidity provider&apos;s only revenue.
        Charging nothing is a static fee. The share was calibrated by searching for the value
        with the least bad worst case across two independent windows of historical flow and the
        full plausible range of uninformed fee elasticity, rather than the value scoring highest
        under one assumption.
      </P>
      <Callout tone="warm" title="The elasticity is bounded, not measured">
        How sharply uninformed flow abandons a pool when its fee rises is assumed, not
        estimated. It is bounded from above by the observation that Uniswap runs ETH/USDC at
        both 5bp and 30bp tiers with real volume at each — which rules out the high end, but
        does not pin the value.
      </Callout>

      <H2 id="fee-cap-overflow">The fee-cap overflow</H2>
      <P>
        A fee expressed as a percentage of notional cannot exceed 100%, and this hook caps far
        below that. On an extreme dislocation the formula wants to charge more than the cap can
        express, and everything past it would be silently discarded.
      </P>
      <P>
        Instead the remainder is recovered as an absolute token amount in the swap&apos;s
        unspecified currency and routed to in-range liquidity providers via{" "}
        <Code>poolManager.donate()</Code>. The hook never holds it: <Code>donate</Code> debits
        the hook and the returned positive delta credits it straight back, so the swapper funds
        the entire amount and the hook ends the transaction with a zero balance. There is no
        escrow, no owner, and no withdrawal path.
      </P>
    </>
  );
}

function V4Constraints() {
  return (
    <>
      <Lede>
        Uniswap v4 shapes this design more than the economics do. Three constraints in
        particular decide what the hook can and cannot be.
      </Lede>

      <H2 id="permissions">Permissions</H2>
      <P>
        A v4 hook&apos;s permissions are encoded in the low bits of its own address, so they are
        fixed at deployment and cannot be changed. Assay claims exactly five —{" "}
        <Code>beforeInitialize</Code>, <Code>afterInitialize</Code>, <Code>beforeSwap</Code>,{" "}
        <Code>afterSwap</Code>, and <Code>afterSwapReturnDelta</Code> — giving mask{" "}
        <Code>{PERMISSION_MASK}</Code>. The address is CREATE2-mined to carry it.
      </P>
      <P>
        It claims no liquidity permissions at all. A liquidity provider can always withdraw; the
        hook is not in that path and structurally cannot block it.
      </P>

      <H2 id="dynamic-fee-handshake">Dynamic fee handshake</H2>
      <P>
        A pool must be created with the dynamic-fee flag for a hook to override its fee.{" "}
        <Code>beforeInitialize</Code> rejects any pool that was not — one of only two places the
        hook ever reverts, and it runs before any liquidity exists.
      </P>
      <P>
        The other rejection is the currency binding. v4 hooks are permissionless, so anyone can
        create a pool naming this one. The reference oracle describes exactly one token pair, so
        a pool of unrelated assets would be priced against a reference for something else
        entirely, while the hook reported that reading as fresh. Refusing at creation is the
        only point where refusal costs nothing.
      </P>

      <H2 id="hot-path">Hot path</H2>
      <P>
        <Code>beforeSwap</Code> must never revert. A revert there is a denial of service against
        every liquidity provider in the pool, so every failure path degrades to a quoted fee
        instead — a stale reference quotes the ceiling rather than erroring.
      </P>
      <DataTable
        head={["Path", "Measured", "Budget"]}
        rows={[
          [
            "Ordinary swap",
            GAS.ordinarySwap.toLocaleString("en-US"),
            GAS.ordinaryBudget.toLocaleString("en-US"),
          ],
          [
            "Block boundary, live feed",
            GAS.blockBoundaryWithLiveFeed.toLocaleString("en-US"),
            GAS.blockBoundaryBudget.toLocaleString("en-US"),
          ],
          [
            "Extreme dislocation",
            GAS.extremeDislocation.toLocaleString("en-US"),
            GAS.extremeBudget.toLocaleString("en-US"),
          ],
        ]}
      />
      <P>
        Reading a Chainlink feed costs roughly{" "}
        {GAS.chainlinkRead.toLocaleString("en-US")} gas, which is why the reference is cached in
        a single packed storage slot and refreshed at most once per block. The common path makes
        no external call at all.
      </P>
    </>
  );
}

function Invariants() {
  return (
    <>
      <Lede>
        The properties the code is built to hold, each covered by tests. These are what an
        auditor should try to break.
      </Lede>

      <H2 id="live-properties">Live properties</H2>
      <Ul>
        <li>
          <strong className="text-text">beforeSwap and afterSwap never revert</strong> for a
          well-formed swap on any pool state. Every failure degrades to a quoted fee.
        </li>
        <li>
          <strong className="text-text">Every quoted fee lies within the advertised range</strong>{" "}
          that <Code>feeBounds()</Code> reports, so a router reading it before quoting is not
          misled.
        </li>
        <li>
          <strong className="text-text">The surcharge nets to exactly zero for the hook.</strong>{" "}
          <Code>donate</Code> debits it and the returned delta repays it, leaving the swapper as
          the sole funder and the hook holding no balance.
        </li>
        <li>
          <strong className="text-text">Only bound pools may attach</strong> — the currencies
          must match the pair the reference oracle declares.
        </li>
        <li>
          <strong className="text-text">A degraded reference degrades upward.</strong> Stale,
          reverting, or out-of-range readings quote the ceiling rather than presenting a wrong
          price as correct.
        </li>
        <li>
          <strong className="text-text">A fresh reference is checked twice.</strong> A reading
          the oracle reports as usable is additionally compared against a smoothed average of
          the pool&apos;s own tick, sampled once per block; one that disagrees by more than the
          configured cap is treated as stale.
        </li>
      </Ul>

      <H2 id="not-applicable">Not applicable</H2>
      <P>
        The original design specified a rebate ledger with ERC-6909 accounting, EIP-712 router
        attestations, and an on-chain logistic classifier. None of it is built, so the
        invariants covering ledger solvency and attestation replay do not apply. See{" "}
        <Link href="/docs/not-built">what is not built</Link>.
      </P>
    </>
  );
}

function Risk() {
  return (
    <>
      <Lede>
        This code is unaudited and has never held value. What follows is the list of things that
        could go wrong and have not been ruled out — stated here rather than left for a reader
        to discover.
      </Lede>

      <Callout tone="warm" title="The adverse-selection gate does not pass">
        <p className="mb-2">
          The pre-declared gate for this project was that the mechanism demonstrably improves
          liquidity-provider outcomes. It does not currently pass. The classifier&apos;s area
          under the curve came in at 0.7485 against a 0.75 floor, on 91 positive examples against
          a floor of 100, with the weakest walk-forward fold at 0.469 against a floor of 0.60.
        </p>
        <p>
          The mechanism is implemented, tested and deployed. The evidence that it is worth
          deploying is not established. Those are different claims and this project does not
          conflate them.
        </p>
      </Callout>

      <H2 id="known-gaps">Known gaps</H2>
      <Ul>
        <li>
          <strong className="text-text">No independent audit.</strong> Reentrancy through{" "}
          <Code>donate</Code> and cross-swap fee manipulation via the tick recorded in{" "}
          <Code>afterSwap</Code> have been reasoned about and partially mutation-tested, but not
          reviewed by a third party.
        </li>
        <li>
          <strong className="text-text">The deviation cap is reasoned, not calibrated.</strong>{" "}
          Its bound comes from tick-space reasoning about the gap between real volatility and
          order-of-magnitude feed errors, not from fitted feed-failure data. It catches gross
          errors, not a subtly wrong value inside the tolerance.
        </li>
        <li>
          <strong className="text-text">No L2 sequencer uptime check.</strong> Analysed and
          accepted: the aggregator cannot update while the sequencer is down, so the existing
          staleness check fires and the pool over-charges rather than under-charges. The residual
          cost is a window of ceiling-priced swaps after a restart.
        </li>
        <li>
          <strong className="text-text">Aggregator circuit breakers unchecked.</strong>{" "}
          Non-binding on the deployed feed, where the bounds are sentinel defaults orders of
          magnitude outside any reachable price. Would need revisiting against a different feed.
        </li>
        <li>
          <strong className="text-text">The capture share&apos;s elasticity is bounded, not
          measured.</strong> See the mechanism page.
        </li>
      </Ul>

      <H2 id="anticipated-attacks">Anticipated attacks</H2>
      <DataTable
        head={["Attack", "Mitigation"]}
        rows={[
          [
            "Attaching the hook to a foreign pool",
            "Currency-pair binding in beforeInitialize, both halves covered by tests",
          ],
          [
            "Unsettled delta bricking every swap",
            "donate plus the returned positive delta net to exactly zero",
          ],
          [
            "Surcharge donation with zero in-range liquidity",
            "Pool.donate reverts there; guarded and skipped rather than reverting the swap",
          ],
          [
            "Self-dealing: attacker is the sole in-range LP",
            "Net cost (1−s)·S; at s=1 there is no counterparty left to extract from",
          ],
          [
            "Oracle manipulation of the mispricing signal",
            "Staleness bound, degrade to the ceiling, and a deviation cap against a block-sampled pool average",
          ],
          [
            "Intra-block price manipulation of that average",
            "The average samples the block-open tick, so a same-block swap cannot move it",
          ],
        ]}
      />
    </>
  );
}

function NotBuilt() {
  return (
    <>
      <Lede>
        The original design specified considerably more than what shipped. Naming the difference
        is more useful than a feature list, and a reader deserves to know which parts of the
        original claim survived contact with data.
      </Lede>

      <H2 id="measured-and-removed">Measured and removed</H2>
      <P>
        The design called for a posterior probability that an order is informed, computed from
        six on-chain microstructure signals. Two of those — realised variance and order-flow
        imbalance — were built, tested, and wired into the swap path.
      </P>
      <P>
        Calibration then measured their <em>incremental</em> value over simply reading the
        reference price. It came in at <strong className="text-text">−0.008 and −0.002</strong>{" "}
        across two independent windows: negative in ten of twelve horizon and threshold
        combinations. They were making the classifier no better while billing every swap for the
        gas.
      </P>
      <P>
        They were removed from the swap path. The libraries remain in the tree, pure and tested,
        for a milestone that can show they earn their cost. Two earlier errors had hidden this
        result — a markout horizon that silently resolved to a wider window than intended, and a
        comparison of univariate rather than incremental discrimination.
      </P>
      <Callout title="Why this is on the docs site and not in a footnote">
        A negative result about the project&apos;s own central mechanism is the most useful thing
        it knows. Publishing only the parts that worked would make everything else here less
        believable, not more.
      </Callout>

      <H2 id="contracts-that-do-not-exist">Contracts that do not exist</H2>
      <P>
        There is no rebate ledger, no ERC-6909 accounting, no EIP-712 router attestation, no
        on-chain logistic classifier, and no growth-optimal fee curve lookup table. The design
        described all of them.
      </P>
      <P>
        The growth-optimal curve in particular is blocked on three parameters — baseline volume,
        volume decay in fee, and arbitrage arrival intensity — that have not been estimated from
        data. Shipping a curve with invented parameters would be worse than shipping a mechanism
        whose single parameter is honest.
      </P>
      <P>
        On the interface side: pools, positions, portfolio and activity surfaces are not built,
        there is no light theme, and swap execution is not wired because no pool exists to
        execute against.
      </P>
    </>
  );
}

export const DOC_BODIES: Record<string, () => React.JSX.Element> = {
  introduction: Introduction,
  mechanism: Mechanism,
  "v4-constraints": V4Constraints,
  invariants: Invariants,
  risk: Risk,
  "not-built": NotBuilt,
};
