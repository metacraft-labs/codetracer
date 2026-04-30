import globals from "globals";
import pluginJs from "@eslint/js";
import tseslint from "typescript-eslint";
import love from "eslint-config-love";

export default [
  { files: ["**/*.{js,mjs,cjs,ts}"] },
  { ignores: ["*.mjs", "*.config.ts"] },
  { languageOptions: { globals: globals.node } },
  pluginJs.configs.recommended,
  ...tseslint.configs.recommended,
  love,
];
