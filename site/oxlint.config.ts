import { defineConfig } from "oxlint";
import antiSlop from "ultracite/oxlint/anti-slop";
import astro from "ultracite/oxlint/astro";
import core from "ultracite/oxlint/core";

export default defineConfig({
  env: core.env,
  extends: [core, astro, antiSlop],
  ignorePatterns: core.ignorePatterns,
  overrides: [
    {
      files: ["**/*.astro", "**/*.svelte"],
      rules: {
        "unicorn/filename-case": [
          "error",
          { cases: { kebabCase: true, pascalCase: true } },
        ],
      },
    },
  ],
});
