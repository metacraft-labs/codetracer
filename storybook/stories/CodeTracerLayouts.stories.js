import { story } from "./CodeTracerSurfaces.stories.js";

const meta = {
  title: "CodeTracer/Layouts",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const DefaultDebug = story("layout", "default-debug", "populated", "Default Debug");
export const NoirFilesystemActive = story(
  "layout",
  "default-debug",
  "filesystem-active",
  "Noir Filesystem Active",
);
export const NoirStateActive = story(
  "layout",
  "default-debug",
  "state-active",
  "Noir State Active",
);
export const NoirCalltraceActive = story(
  "layout",
  "default-debug",
  "calltrace-active",
  "Noir Calltrace Active",
);
export const NoirCalltraceSearchStatusReport = story(
  "layout",
  "default-debug",
  "calltrace-search-status-report",
  "Noir Calltrace Search Status Report",
);
export const NoirMenuViewOpen = story(
  "layout",
  "default-debug",
  "menu-view-open",
  "Noir Menu View Open",
);
export const NoirStatusExpanded = story(
  "layout",
  "default-debug",
  "status-expanded",
  "Noir Status Expanded",
);
export const StandaloneAppShell = story(
  "layout",
  "standalone-app-shell",
  "populated",
  "Standalone App Shell",
);
export const Welcome = story("panel", "welcome-screen", "populated", "Welcome");
