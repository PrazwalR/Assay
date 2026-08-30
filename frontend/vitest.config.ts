import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

/**
 * Vitest does not read `tsconfig.json` paths, so the `@/` alias has to be declared here too.
 * Without it, any test importing a module that itself uses `@/` fails to resolve — which is a
 * failure of the harness, not of the code, and the least useful kind of red.
 */
export default defineConfig({
  resolve: {
    alias: {
      "@": fileURLToPath(new URL("./src", import.meta.url)),
    },
  },
});
