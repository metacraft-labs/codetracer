import { story } from "./CodeTracerSurfaces.stories.js";

const meta = {
  title: "CodeTracer/Fixtures",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const BuildRunning = story("panel", "build", "loading", "Build Running");
export const ErrorsEmpty = story("panel", "errors", "empty", "Errors Empty");
export const TerminalEmpty = story("panel", "terminal-output", "empty", "Terminal Empty");
export const TerminalLoading = story("panel", "terminal-output", "loading", "Terminal Loading");
export const WelcomeRecord = story("panel", "welcome-screen", "record", "Welcome Record");
export const WelcomeOnlineTrace = story(
  "panel",
  "welcome-screen",
  "online",
  "Welcome Online Trace",
);
