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
export const NoirFixedSearchVisible = story(
  "layout",
  "default-debug",
  "fixed-search-visible",
  "Noir Fixed Search Visible",
);
export const NoirSearchResultsPopulated = story(
  "layout",
  "default-debug",
  "search-results-populated",
  "Noir Search Results Populated",
);
export const NoirCommandPaletteOpen = story(
  "layout",
  "default-debug",
  "command-palette-open",
  "Noir Command Palette Open",
);
export const NoirBuildOpen = story(
  "layout",
  "default-debug",
  "build-open",
  "Noir Build Open",
);
export const NoirTraceLogOpen = story(
  "layout",
  "default-debug",
  "trace-log-open",
  "Noir Trace Log Open",
);
export const NoirDebugControlsHeader = story(
  "layout",
  "default-debug",
  "debug-controls-header",
  "Noir Debug Controls Header",
);
export const StandaloneAppShell = story(
  "layout",
  "standalone-app-shell",
  "populated",
  "Standalone App Shell",
);
export const Welcome = story("panel", "welcome-screen", "populated", "Welcome");
