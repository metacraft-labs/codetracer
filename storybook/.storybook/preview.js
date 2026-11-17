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
    // Where a playback story of the Agent Harbor section opens: one of its
    // scenario's named moments (`?id=<story>&globals=moment:<name>`), the
    // first frame when unset. No toolbar: the story's own playback bar plays
    // and seeks it (`isonim_agent_harbor_playback_view.nim`).
    moment: {
      description: "The named moment a playback story opens at",
      defaultValue: "",
    },
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
