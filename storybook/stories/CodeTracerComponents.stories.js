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
export const AutoHideBottomStrip = story("component", "auto-hide-bottom-strip", "populated", "Auto Hide Bottom Strip");
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
