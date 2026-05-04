import { expect } from "@storybook/test";

declareMount();

let loadPromise = null;

function declareMount() {
  if (typeof window !== "undefined" && !window.__codetracerStorybookLoaded) {
    window.__codetracerStorybookLoaded = false;
  }
}

function ensureComponentsLoaded() {
  if (typeof mountCodeTracerStory !== "undefined") {
    return Promise.resolve();
  }

  if (!loadPromise) {
    loadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "./dist/components.js";
      script.onload = () => {
        window.__codetracerStorybookLoaded = true;
        resolve();
      };
      script.onerror = () =>
        reject(
          new Error(
            "Failed to load storybook/dist/components.js. Run: just build-storybook-components",
          ),
        );
      document.head.appendChild(script);
    });
  }

  return loadPromise;
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function titleize(name) {
  return name
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function injectSurfaceStyles(container) {
  const style = document.createElement("style");
  style.textContent = `
    .ct-storybook-surface {
      box-sizing: border-box;
      min-height: 100vh;
      padding: 0;
    }

    .ct-storybook-frame {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-height: 100%;
      overflow: auto;
    }

    .ct-storybook-root-container {
      top: 0 !important;
      height: 100vh !important;
    }

    .ct-storybook-root-container #main.ct-storybook-frame {
      flex-wrap: nowrap;
      min-height: 0;
    }

    .ct-storybook-golden-panel {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      width: 100%;
      min-width: 0;
      min-height: 0;
      height: 100%;
    }

    .ct-storybook-golden-panel .lm_stack {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-golden-panel .lm_header {
      box-sizing: border-box;
      display: flex;
      align-items: flex-end;
      flex: 0 0 30px;
      min-height: 30px;
      height: 30px !important;
      overflow: visible;
    }

    .ct-storybook-golden-panel .lm_tabs {
      box-sizing: border-box;
      align-items: flex-end;
      height: 30px;
      margin: 0;
      padding: 0 30px 0 0;
    }

    .ct-storybook-golden-panel .lm_controls {
      box-sizing: border-box;
      display: flex !important;
      align-items: center !important;
      height: 30px !important;
      top: 0 !important;
      right: 0 !important;
    }

    .ct-storybook-golden-panel .lm_controls > * {
      box-sizing: border-box;
      width: 16px !important;
      height: 16px !important;
      margin-top: 0 !important;
    }

    .ct-storybook-golden-panel .lm_items {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 auto;
      min-height: 0;
      width: 100%;
    }

    .ct-storybook-golden-panel .lm_content {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-panel-content {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-panel-content > .component-container,
    .ct-storybook-panel-content > .component-container.terminal,
    .ct-storybook-panel-content > .terminal,
    .ct-storybook-panel-content > .build-panel,
    .ct-storybook-panel-content > .panel {
      box-sizing: border-box;
      flex: 1 1 100%;
      width: 100%;
      min-width: 0;
      height: 100%;
      min-height: 0;
    }

    .ct-storybook-frame > .component-container,
    .ct-storybook-frame > .component-container.terminal,
    .ct-storybook-frame > .terminal,
    .ct-storybook-frame > .build-panel,
    .ct-storybook-frame > .panel,
    .ct-storybook-frame > .isonim-app-shell {
      box-sizing: border-box;
      flex: 1 1 100%;
      width: 100%;
      min-width: 0;
      min-height: 100vh;
    }
  `;
  container.appendChild(style);
}

function createGoldenPanelHost(frame, title) {
  const layout = document.createElement("div");
  layout.className = "lm_goldenlayout lm_item lm_root ct-storybook-golden-panel";

  const stack = document.createElement("div");
  stack.className = "lm_item lm_stack";

  const header = document.createElement("div");
  header.className = "lm_header";

  const tabs = document.createElement("ul");
  tabs.className = "lm_tabs";

  const tab = document.createElement("li");
  tab.className = "lm_tab lm_active";

  const tabTitle = document.createElement("span");
  tabTitle.className = "lm_title";
  tabTitle.textContent = title;
  tab.appendChild(tabTitle);

  const closeTab = document.createElement("div");
  closeTab.className = "lm_close_tab";
  tab.appendChild(closeTab);
  tabs.appendChild(tab);
  header.appendChild(tabs);

  const controls = document.createElement("div");
  controls.className = "lm_controls";
  for (const controlClass of ["lm_maximise", "lm_close"]) {
    const control = document.createElement("div");
    control.className = controlClass;
    controls.appendChild(control);
  }
  header.appendChild(controls);

  const items = document.createElement("div");
  items.className = "lm_items";

  const content = document.createElement("div");
  content.className = "lm_item lm_content";

  const mount = document.createElement("div");
  mount.className = "ct-storybook-panel-content";
  content.appendChild(mount);
  items.appendChild(content);
  stack.appendChild(header);
  stack.appendChild(items);
  layout.appendChild(stack);
  frame.appendChild(layout);

  return mount;
}

function createAppShell(container, kind, name) {
  if (kind === "view" || kind === "component") {
    const frame = document.createElement("div");
    frame.className = "ct-storybook-frame";
    container.appendChild(frame);
    return frame;
  }

  const rootContainer = document.createElement("div");
  rootContainer.id = "root-container";
  rootContainer.className = "ct-storybook-root-container";

  const layoutRow = document.createElement("div");
  layoutRow.id = "auto-hide-layout-row";

  const leftStrip = document.createElement("div");
  leftStrip.id = "auto-hide-strip-left";

  const root = document.createElement("div");
  root.id = "ROOT";

  const contextMenu = document.createElement("div");
  contextMenu.id = "context-menu-container";
  contextMenu.style.display = "none";
  root.appendChild(contextMenu);

  const fixedSearch = document.createElement("div");
  fixedSearch.id = "fixed-search";
  root.appendChild(fixedSearch);

  const session = document.createElement("div");
  session.id = "session-container-0";
  session.className = "session-container";

  const frame = document.createElement("section");
  frame.id = "main";
  frame.className = "ct-storybook-frame";
  session.appendChild(frame);
  root.appendChild(session);

  const rightStrip = document.createElement("div");
  rightStrip.id = "auto-hide-strip-right";

  layoutRow.appendChild(leftStrip);
  layoutRow.appendChild(root);
  layoutRow.appendChild(rightStrip);
  rootContainer.appendChild(layoutRow);
  container.appendChild(rootContainer);

  if (kind === "panel") {
    return createGoldenPanelHost(frame, titleize(name));
  }

  return frame;
}

function renderSurface(kind, name, fixture = "populated") {
  const container = document.createElement("div");
  container.className = "ct-storybook-surface";
  container.dataset.kind = kind;
  container.dataset.surface = name;
  injectSurfaceStyles(container);

  const frame = createAppShell(container, kind, name);

  ensureComponentsLoaded().then(() => {
    const dispose = mountCodeTracerStory(frame, kind, name, fixture);
    container.__dispose = dispose;
  });

  return container;
}

function story(kind, name, fixture = "populated") {
  return {
    render: () => renderSurface(kind, name, fixture),
    play: async ({ canvasElement }) => {
      await ensureComponentsLoaded();
      await tick();
      const frame = canvasElement.querySelector(".ct-storybook-frame");
      expect(frame).toBeTruthy();
      expect(frame.children.length).toBeGreaterThan(0);
    },
  };
}

const meta = {
  title: "CodeTracer/Surfaces",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const LayoutStandaloneAppShell = story("layout", "standalone-app-shell");
export const LayoutDefaultDebug = story("layout", "default-debug");
export const LayoutWelcome = story("panel", "welcome-screen");

export const PanelAgentActivity = story("panel", "agent-activity");
export const PanelAgentActivityDeepReview = story("panel", "agent-activity-deepreview");
export const PanelAgentWorkspace = story("panel", "agent-workspace");
export const PanelBuild = story("panel", "build");
export const PanelCalltrace = story("panel", "calltrace");
export const PanelCalltraceEditor = story("panel", "calltrace-editor");
export const PanelCommandPalette = story("panel", "command-palette");
export const PanelDebugControls = story("panel", "debug-controls");
export const PanelDeepReview = story("panel", "deepreview");
export const PanelEditor = story("panel", "editor");
export const PanelErrors = story("panel", "errors");
export const PanelEventLog = story("panel", "event-log");
export const PanelFilesystem = story("panel", "filesystem");
export const PanelFlow = story("panel", "flow");
export const PanelLowLevelCode = story("panel", "low-level-code");
export const PanelNoSource = story("panel", "no-source");
export const PanelPointList = story("panel", "point-list");
export const PanelRepl = story("panel", "repl");
export const PanelRequestPanel = story("panel", "request-panel");
export const PanelScratchpad = story("panel", "scratchpad");
export const PanelSearch = story("panel", "search");
export const PanelSearchResults = story("panel", "search-results");
export const PanelShell = story("panel", "shell");
export const PanelState = story("panel", "state");
export const PanelStepList = story("panel", "step-list");
export const PanelTerminalOutput = story("panel", "terminal-output");
export const PanelTimeline = story("panel", "timeline");
export const PanelTraceLog = story("panel", "trace-log");
export const PanelVcs = story("panel", "vcs");
export const PanelWelcomeScreen = story("panel", "welcome-screen");

export const FixtureBuildRunning = story("panel", "build", "loading");
export const FixtureErrorsEmpty = story("panel", "errors", "empty");
export const FixtureTerminalEmpty = story("panel", "terminal-output", "empty");
export const FixtureTerminalLoading = story("panel", "terminal-output", "loading");
export const FixtureWelcomeRecord = story("panel", "welcome-screen", "record");
export const FixtureWelcomeOnlineTrace = story("panel", "welcome-screen", "online");

export const ViewMenuShell = story("view", "menu-shell");
export const ViewStatusShell = story("view", "status-shell");
export const ViewSessionTabs = story("view", "session-tabs");
export const ViewDebugShell = story("view", "debug-shell");
export const ViewAutoHideBottomTabs = story("view", "auto-hide-bottom-tabs");
export const ViewAutoHideCollapsedIcons = story("view", "auto-hide-collapsed-icons");
export const ViewAutoHideOverlayTabs = story("view", "auto-hide-overlay-tabs");
export const ViewAutoHideSideStrip = story("view", "auto-hide-side-strip");
export const ViewAutoHideSideStripCollapsed = story(
  "view",
  "auto-hide-side-strip",
  "collapsed",
);

export const ComponentMenuShell = story("component", "menu-shell");
export const ComponentStatusShell = story("component", "status-shell");
export const ComponentSessionTabs = story("component", "session-tabs");
export const ComponentAutoHideBottomTabs = story("component", "auto-hide-bottom-tabs");
export const ComponentAutoHideCollapsedIcons = story(
  "component",
  "auto-hide-collapsed-icons",
);
export const ComponentAutoHideOverlayTabs = story("component", "auto-hide-overlay-tabs");
export const ComponentAutoHideSideStrip = story("component", "auto-hide-side-strip");
