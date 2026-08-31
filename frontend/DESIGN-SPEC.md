# Assay frontend — design spec for the Next.js port

Prototype: `frontend/Assay.dc.html` (interactive, four surfaces: Overview, Swap, Markets, Docs).
This file is the handoff: tokens, component inventory, and the rules that keep the port honest.

Everything numeric in the prototype is derived from the contracts, not invented. Sources are cited
per value below.

---

## 1. Brand

The mark is the supplied `Assay.svg`, cleaned of C2PA metadata and cropped to the glyph:

- `frontend/assets/assay-mark.svg` — `fill="currentColor"`, viewBox `480 560 1100 932`
- `frontend/assets/assay-mark-light.svg` — `#E7EAEC`, for dark surfaces
- `frontend/assets/assay-mark-dark.svg` — `#0A0B0C`, for light surfaces

Use the `currentColor` variant as an inline React component so it inherits text colour. Never
recolour the mark to the accent.

## 2. Colour tokens

Dark is the only built theme. Names are semantic; do not scatter raw hex in components.

```ts
// tailwind.config.ts → theme.extend.colors
const colors = {
  bg:            '#0A0B0C', // page
  surface:       '#0E1011', // cards, header panels
  'surface-2':   '#101214', // header chips, inputs on page bg
  'surface-3':   '#131617', // inputs inside cards
  'surface-4':   '#151819', // hover
  'surface-5':   '#191C1E', // pills, token buttons
  border:        'rgba(233,236,239,0.07)',
  'border-2':    'rgba(233,236,239,0.09)',
  'border-hover':'rgba(233,236,239,0.22)',
  text:          '#E7EAEC',
  'text-2':      '#B7BCC0', // doc lede
  'text-dim':    '#9BA1A6', // body
  'text-muted':  '#6B7278', // labels, meta
  'text-ghost':  '#3A3F42', // empty numerals, rules
  accent:        '#4FC3E8', // RESERVED: live fee readout, base-fee state, links, focus
  benign:        '#5BD08C', // drift < 0 — trading away from reference
  warm:          '#E9A544', // drift 41…500 — capturing, surcharged
  hot:           '#E4674F', // drift > 500, at cap, stale reference, errors
};
```

State washes (backgrounds/borders for the tone a quote is in):

| tone | when | text/line | wash | border |
| --- | --- | --- | --- | --- |
| benign | `drift < 0` | `#5BD08C` | `rgba(91,208,140,.06)` | `rgba(91,208,140,.22)` |
| base | `0 ≤ drift ≤ 40` | `#4FC3E8` | `rgba(79,195,232,.06)` | `rgba(79,195,232,.22)` |
| warm | `41 ≤ drift ≤ 500` | `#E9A544` | `rgba(233,165,68,.06)` | `rgba(233,165,68,.24)` |
| hot | `drift > 500` or stale | `#E4674F` | `rgba(228,103,79,.07)` | `rgba(228,103,79,.26)` |

**Accent discipline.** `accent` appears on: the quote-surface curve, the base-fee state, links,
input focus rings, the AssayHook node in the route, active nav/tab indicators. Nothing else.
Neutrals carry the rest of the interface.

## 3. Type

Two families, both Google Fonts.

```
Archivo        400 / 500 / 600 / 700   UI, headings, prose
JetBrains Mono 400 / 500 / 600         ALL financial data, addresses, code, labels
```

Every number a user could act on is mono with `font-variant-numeric: tabular-nums`.

| role | spec |
| --- | --- |
| display | Archivo 600, `clamp(38px,5.4vw,74px)`, lh 1.03, tracking −.035em |
| h1 (page) | Archivo 600, 32–36px, lh 1.15, tracking −.03em |
| h2 | Archivo 600, 22–26px, lh 1.2–1.25, tracking −.02em |
| lede | Archivo 400, 16–17px, lh 1.6–1.7, `text-wrap:pretty`, max 70ch |
| body | Archivo 400, 14.5–15px, lh 1.6–1.7 |
| UI label | Archivo 500, 12.5–13.5px |
| eyebrow | JetBrains Mono 500, 10.5px, tracking .12em, uppercase, `text-muted` |
| metric large | JetBrains Mono 500/600, 24–30px, tabular |
| metric row | JetBrains Mono 400, 12.5–13.5px, tabular |
| code block | JetBrains Mono 400, 13.5px, lh 2 |

## 4. Geometry

4px rhythm; 8px for card interiors. Radii: `4` badge · `7` small control · `8–9` chip/button ·
`10–12` input/inner card · `14–16` card · `18` primary card/modal · `19` pill (token button) ·
`50%` token icon.

Heights: header `60px` · control `29–34px` · input `42px` · token button `38px` · primary CTA
`50px` · modal max-width `420–440px`, max-height `82vh`.

Elevation is used twice only: swap card `0 24px 60px -30px rgba(0,0,0,.9)`, modal
`0 40px 90px -30px rgba(0,0,0,.9)`. Everything else separates with a 1px border or a 1px grid gap
(`gap:1px` over a border-coloured background — used for every metric strip and detail list).

## 5. Motion

| interaction | spec |
| --- | --- |
| button hover | `translateY(-1px)` + soft shadow, 160ms ease |
| token button hover | `scale(1.03)`, 160ms |
| direction flip | `rotate(180deg) scale(1.08)`, 280ms `cubic-bezier(.34,1.56,.64,1)`, fills accent |
| modal enter | `assayRise` — 6px up + fade, 260ms `cubic-bezier(.22,1,.36,1)`; scrim 180ms |
| curve draw | `stroke-dashoffset` 240→0, 2.2s ease-out, once on mount |
| live marker | `assayRipple` scale .6→2.4 + fade, 1.8s infinite |
| freshness dot | `assayPulse` opacity .35↔1, 2.4–2.6s infinite |
| pending | 0.9s linear spin on a 2px ring |
| success | ripple behind a static check (no confetti) |

All of it sits inside `@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}`,
and the live-market random walk does not start when that query matches.

## 6. Component inventory

Built in the prototype, in the order worth porting:

`AppShell` (status banner · Header · route outlet · Footer) · `Header` (mark, nav, DataModeToggle,
NetworkPill, WalletButton) · `QuoteCurve` (the signature visual; pointer-draggable) ·
`MetricStrip` · `SwapCard` · `TokenAmountInput` · `TokenButton` · `DirectionFlip` ·
`QuoteToneBanner` · `DetailList` · `ErrorPanel` · `PrimaryCta` (8 states) · `FreshnessLine` ·
`DriftMeter` (draggable) · `FeeDerivation` · `OverflowNotice` · `TwinQuote` · `RoutePath` ·
`EventLog` · `Modal` (shell + Token / Wallet / Network / Settings / Tx / Search bodies) ·
`RangeTabs` · `ScatterChart` · `DistributionBars` · `PoolTable` + empty row · `DocsSidebar` ·
`DocsToc` · `DocsPrevNext` · `CodeBlock` · `Callout`.

Interaction states covered in the prototype: default, hover, focus-within on inputs, disabled CTA,
insufficient balance, stale reference, fee-cap overflow, empty token search, empty doc search,
no-other-pools empty row, pending tx, confirmed tx, copied address, disabled networks.

## 7. The mechanism — port this exactly

`FeeBlend.sol` is the source of truth. TypeScript mirror (already in the prototype):

```ts
const BASE_FEE = 500, MIN_FEE = 100, MAX_FEE = 10_000, SHARE_BPS = 1_000;

function rawPips(driftTicks: number) {
  const scaled = clamp(driftTicks, -200_000, 200_000) * 100 * SHARE_BPS;
  let surcharge = Math.trunc(scaled / 10_000);
  if (scaled > 0 && scaled % 10_000 !== 0) surcharge += 1; // ceil toward +∞, LP's favour
  return BASE_FEE + surcharge;
}
const quote      = (d: number, fresh: boolean) => fresh ? clamp(rawPips(d), MIN_FEE, MAX_FEE) : MAX_FEE;
const overflow   = (d: number, fresh: boolean) => fresh ? Math.max(0, Math.min(1_000_000, rawPips(d) - MAX_FEE)) : 0;
```

Consequences the UI must not contradict:

- One tick of drift = 100 pips of fee before the share; at 1,000 bps each tick adds **10 pips**.
- The cap binds at **950 ticks**; below **−40 ticks** the floor binds.
- A stale reference quotes the **ceiling**, never an error, never a revert.
- Rounding is toward +∞ on the capturing side. Never display a fee lower than `quote()`.
- `sender` is the router. Never label it as the trader or a user identity.

Deployed values (`.env`, `AssayConfig.sol`, `DeployAssay.s.sol`): `baseFeePips 500`,
`minFeePips 100`, `maxFeePips 10000`, `captureShareBps 1000`, mask `0x30C4`, runtime 9,625 bytes,
hook `0xa3A9901c03bB63232abaA7493AA4a21b71B5b0c4`, oracle adapter
`0x68E65451A97261B451f186e9B9099c3fBF7efc90`, Base Sepolia (84532).

Gas (`README.md`, `docs/gas.md`): ordinary swap 14,572 / 20,000 · block boundary 30,901 +~16,500
live-feed premium / 55,000 · extreme dislocation 48,582 / 55,000 · a live Chainlink read 20,774.

Events shown in the log are the real ones from `IAssayEvents.sol`: `PoolRegistered`,
`SwapAssayed`, `ReferenceFreshnessChanged` (transition only, not per swap),
`ToxicitySurchargeDonated`.

## 8. Data layer

Replace the in-component mock with:

```
lib/protocol/config.ts     // immutable deployment constants (§7)
lib/protocol/feeBlend.ts   // the pure port above, unit-tested against DynamicPricing.t.sol
lib/protocol/mock/         // pool, tokens, events, market series — the only place fixtures live
hooks/useQuote.ts          // drift + freshness → fee, tone, overflow
hooks/usePoolState.ts      // pool tick, reference tick, freshness, block
```

Mock values are internally consistent: `poolPrice = REF / 1.0001^drift` with `REF = 3412.60`, and
every USD figure derives from that one price. Keep that property — a UI whose numbers do not
reconcile reads as fake to exactly the audience this protocol needs.

The `dataMode` switch (`base sepolia live` ↔ `mainnet mock`) exists to keep the vision piece and
the testnet reality in one build. Testnet is the default; mainnet mock is explicitly labelled.

## 9. Copy rules

The candour is the brand. Do not soften it in the port.

- Name what is not built and not proven, on the marketing surface, not only in docs.
- Errors state what happened, why, and what the user can do — the stale-reference copy is the
  model.
- No superlatives, no "revolutionary", no protocol-scale claims the repo does not support.
- Lowercase mono for machine facts (addresses, chain ids, states); sentence case Archivo for
  anything addressed to a person.

## 10. Not built yet

Pools/Positions/Portfolio/Activity surfaces, a light theme, mobile-specific layouts (bottom nav,
token bottom sheet, full-screen wallet), skeleton loaders, toasts, keyboard navigation inside the
token list, and real wallet/RPC integration. The token, wallet, network, settings, tx and search
modals are the patterns to extend from.
