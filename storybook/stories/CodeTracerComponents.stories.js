import { story } from "./CodeTracerSurfaces.stories.js";

const meta = {
  title: "CodeTracer/Components",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const MenuShell = story("component", "menu-shell", "populated", "Menu Shell");
export const StatusShell = story("component", "status-shell", "populated", "Status Shell");
export const SessionTabs = story("component", "session-tabs", "populated", "Session Tabs");
export const AutoHideBottomTabs = story("component", "auto-hide-bottom-tabs", "populated", "Auto Hide Bottom Tabs");
export const AutoHideCollapsedIcons = story(
  "component",
  "auto-hide-collapsed-icons",
  "populated",
  "Auto Hide Collapsed Icons",
);
export const AutoHideOverlayTabs = story(
  "component",
  "auto-hide-overlay-tabs",
  "populated",
  "Auto Hide Overlay Tabs",
);
export const AutoHideSideStrip = story("component", "auto-hide-side-strip", "populated", "Auto Hide Side Strip");
