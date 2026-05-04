import { story } from "./CodeTracerSurfaces.stories.js";

const meta = {
  title: "CodeTracer/Layouts",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const DefaultDebug = story("layout", "default-debug", "populated", "Default Debug");
export const StandaloneAppShell = story(
  "layout",
  "standalone-app-shell",
  "populated",
  "Standalone App Shell",
);
export const Welcome = story("panel", "welcome-screen", "populated", "Welcome");
