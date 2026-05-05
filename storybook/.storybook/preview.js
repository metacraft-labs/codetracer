import { loadCodeTracerAppStyles } from "./appStyles.js";

const appStylesReady = loadCodeTracerAppStyles();

const preview = {
  loaders: [
    async () => {
      await appStylesReady;
      return {};
    },
  ],
  parameters: {
    layout: "fullscreen",
  },
};

export default preview;
