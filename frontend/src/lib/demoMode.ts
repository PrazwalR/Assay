/**
 * Demo presentation mode.
 *
 * `NEXT_PUBLIC_DEMO_MODE=true` withholds the status banner and the two Assurance pages
 * (`risk`, `not-built`) from the *built site*. Nothing is deleted: the pages, the banner and
 * every number in them stay in the repository, in `README.md` and in `SECURITY.md`, which is
 * where a reader evaluating this code will look.
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

/** Doc slugs withheld while `DEMO_MODE` is on. Filtered out of the nav graph in `docs.ts`. */
export const DEMO_HIDDEN_DOCS: readonly string[] = ["risk", "not-built"];
