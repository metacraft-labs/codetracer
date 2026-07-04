import type { StorybookConfig } from "@storybook/html-webpack5";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(__dirname, "../..");
const buildDir = existsSync(resolve(repoRoot, "src/build-debug-repro/frontend"))
  ? "build-debug-repro"
  : "build-debug";

const config: StorybookConfig = {
  stories: ["../stories/**/*.stories.@(js|ts)"],
  addons: ["@storybook/addon-essentials", "@storybook/addon-interactions"],
  framework: {
    name: "@storybook/html-webpack5",
    options: {},
  },
  staticDirs: [
    { from: "../dist", to: "/dist" },
    { from: "../../src/frontend/index.html", to: "/codetracer-app-index.html" },
    { from: `../../src/${buildDir}/frontend`, to: "/frontend" },
    { from: `../../src/${buildDir}/public`, to: "/public" },
  ],
};

export default config;
