import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const storybookRoot = fileURLToPath(new URL("..", import.meta.url));
const previewPath = join(storybookRoot, ".storybook", "preview.js");
const storiesDir = join(storybookRoot, "stories");

const appStyles = [
  "default_dark_theme_electron.css",
  "loader.css",
  "goldenlayout-base.css",
  "goldenlayout-light-theme.css",
  "bootstrap.css",
  "bootstrap-grid.css",
  "font-awesome.min.css",
  "vex.css",
  "vex-theme-os.css",
  "jstree_default.css",
  "nouislider.css",
  "file-icons.css",
  "devicon-base.css",
];

const copiedVisualProperties = new Set([
  "background",
  "background-color",
  "background-image",
  "border",
  "border-color",
  "border-radius",
  "border-style",
  "border-width",
  "box-shadow",
  "color",
  "font-family",
  "font-size",
  "font-style",
  "font-weight",
  "letter-spacing",
  "opacity",
]);

const failures = [];
const preview = readFileSync(previewPath, "utf8");

if (!preview.includes("./appStyles.js")) {
  failures.push("storybook/.storybook/preview.js must load CodeTracer app styles through appStyles.js");
}

for (const cssName of appStyles) {
  if (preview.includes(cssName)) {
    failures.push(`storybook/.storybook/preview.js hardcodes app stylesheet ${cssName}`);
  }
}

for (const file of readdirSync(storiesDir).filter((name) => name.endsWith(".stories.js"))) {
  const path = join(storiesDir, file);
  const source = readFileSync(path, "utf8");
  const styleBlocks = source.matchAll(/style\.textContent\s*=\s*`([\s\S]*?)`/g);

  for (const block of styleBlocks) {
    const lines = block[1].split("\n");
    for (const [index, line] of lines.entries()) {
      const declaration = line.match(/^\s*([a-z-]+)\s*:/);
      if (declaration && copiedVisualProperties.has(declaration[1])) {
        failures.push(`${file}: inline Storybook CSS sets ${declaration[1]} at style block line ${index + 1}`);
      }
    }
  }
}

if (failures.length > 0) {
  console.error("Storybook must reuse CodeTracer app/design-system styles:");
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}
