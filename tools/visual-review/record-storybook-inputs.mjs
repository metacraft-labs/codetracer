// record-storybook-inputs.mjs -- write the input record of the StoryBook
// components bundle (`storybook/dist/components.js.inputs.json`) from what its
// compile reported. Run by `scripts/build-storybook-components.sh` after a
// successful compile and before it stamps the compile; the record's contents
// and how `requireFreshStorybookStatic` checks them are described at
// `INPUTS_RECORD` in `storybook-freshness.mjs`.
//
// Usage:
//   node tools/visual-review/record-storybook-inputs.mjs \
//     <repo-root> <project.nim> <compiler .deps file> <fixture inputs .json> <out>
//
// Exits non-zero, writing nothing, when an input cannot be read: a bundle with
// no record is refused, which is the safe outcome of a recording that failed.

import { readFileSync } from "node:fs";
import { collectStorybookInputs, writeStorybookInputs } from "./storybook-freshness.mjs";

const [repoRoot, projectFile, depsFile, fixtureFile, out] = process.argv.slice(2);
if (!out) {
  console.error(
    "usage: record-storybook-inputs.mjs <repo-root> <project.nim> <deps-file> <fixture-inputs.json> <out>",
  );
  process.exit(2);
}
try {
  const depsText = readFileSync(depsFile, "utf8");
  const fixture = JSON.parse(readFileSync(fixtureFile, "utf8"));
  writeStorybookInputs(out, collectStorybookInputs({ repoRoot, projectFile, depsText, fixture }));
} catch (error) {
  console.error(`record-storybook-inputs: ${error.message}`);
  process.exit(1);
}
