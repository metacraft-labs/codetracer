import { story } from "./CodeTracerSurfaces.stories.js";

const meta = {
  title: "CodeTracer/Views",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const MenuShell = story("view", "menu-shell", "populated", "Menu Shell");
export const StatusShell = story("view", "status-shell", "populated", "Status Shell");
export const SessionTabs = story("view", "session-tabs", "populated", "Session Tabs");
export const DebugShell = story("view", "debug-shell", "populated", "Debug Shell");
export const AutoHideBottomTabs = story(
  "view",
  "auto-hide-bottom-tabs",
  "populated",
  "Auto Hide Bottom Tabs",
);
export const AutoHideCollapsedIcons = story(
  "view",
  "auto-hide-collapsed-icons",
  "populated",
  "Auto Hide Collapsed Icons",
);
export const AutoHideOverlayTabs = story(
  "view",
  "auto-hide-overlay-tabs",
  "populated",
  "Auto Hide Overlay Tabs",
);
export const AutoHideSideStrip = story(
  "view",
  "auto-hide-side-strip",
  "populated",
  "Auto Hide Side Strip",
);
export const AutoHideSideStripCollapsed = story(
  "view",
  "auto-hide-side-strip",
  "collapsed",
  "Auto Hide Side Strip Collapsed",
);
