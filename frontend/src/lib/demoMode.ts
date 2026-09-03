/**
 * Demo presentation mode.
 *
 * `NEXT_PUBLIC_DEMO_MODE=true` withholds the *repeated chrome* from the built site: the status
 * banner that sits above every page, the "What this does not yet show" panel on the overview,
 * and the aggregates disclosure on markets. These say the same thing on every screen, which is
 * right for a visitor and wrong for video, where the same paragraph in every frame reads as
 * boilerplate rather than as candour.
 *
 * It does **not** touch the docs. `/docs/risk` and `/docs/not-built` are always built and always
 * reachable, in every mode. An earlier revision filtered them out of the nav graph, which also
 * made them 404 — and `/docs/risk` is the page the demo's closing shot is *about*, so hiding it
 * broke the very argument the video ends on. The disclosure is not the chrome; the chrome is
 * just where the disclosure repeats itself.
 *
 * The default is unset, and unset is the full-disclosure build. A fresh checkout, a local
 * `pnpm dev` and CI all show everything; only an environment that explicitly opts in hides
 * anything. Restoring the deployed site is deleting one environment variable in Vercel —
 * deliberately cheaper than remembering to revert a commit.
 *
 * This is a presentation switch for a testnet demo. It is not a claim about the code: the
 * hook is unaudited, has only ever been deployed to Base Sepolia, and its adverse-selection
 * gate does not currently pass. Turning this on before a deployment that could custody real
 * value would be a lie by omission — see `SECURITY.md`.
 */
export const DEMO_MODE = process.env.NEXT_PUBLIC_DEMO_MODE === "true";
