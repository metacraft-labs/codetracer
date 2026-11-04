import { loadCodeTracerAppStyles, setCodeTracerTheme } from "./appStyles.js";

const appStylesReady = loadCodeTracerAppStyles();

const preview = {
  loaders: [
    async ({ globals }) => {
      await appStylesReady;
      await setCodeTracerTheme(globals.theme);
      return {};
    },
  ],
  globalTypes: {
    theme: {
      description: "CodeTracer colour theme",
      defaultValue: "dark",
      toolbar: {
        title: "Theme",
        icon: "mirror",
        items: [
          { value: "dark", title: "Dark" },
          { value: "light", title: "Light" },
        ],
        dynamicTitle: true,
      },
    },
  },
  parameters: {
    layout: "fullscreen",
  },
};

export default preview;
