import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // The design prototype and its generated `x-dc` runtime. Kept in the tree as the reference
    // this app was ported from, but neither authored here nor shipped — linting it reports on
    // someone else's generated code.
    "prototype/**",
  ]),
]);

export default eslintConfig;
