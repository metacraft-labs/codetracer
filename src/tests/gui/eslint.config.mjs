import globals from "globals";
import pluginJs from "@eslint/js";
import tseslint from "typescript-eslint";
import love from "eslint-config-love";

const tsRecommended = tseslint.configs.recommended.map((config) => {
  if (!config.plugins?.["@typescript-eslint"]) return config;
  const { plugins: configPlugins, ...configWithoutPlugins } = config;
  const { "@typescript-eslint": _typescriptEslint, ...plugins } = configPlugins;
  return Object.keys(plugins).length > 0
    ? { ...configWithoutPlugins, plugins }
    : configWithoutPlugins;
});

export default [
  { files: ["**/*.{js,mjs,cjs,ts}"] },
  { ignores: ["*.mjs", "*.config.ts"] },
  { languageOptions: { globals: globals.node } },
  pluginJs.configs.recommended,
  ...tsRecommended,
  love,
];
