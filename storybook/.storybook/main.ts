import type { StorybookConfig } from "@storybook/html-webpack5";

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
    { from: "../../src/build-debug/frontend", to: "/frontend" },
    { from: "../../src/build-debug/public", to: "/public" },
  ],
};

export default config;
