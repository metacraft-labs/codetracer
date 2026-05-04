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

function injectSurfaceStyles(container) {
  const style = document.createElement("style");
  style.textContent = `
    .ct-storybook-surface {
      box-sizing: border-box;
      min-height: 100vh;
      padding: 16px;
      background: #17191d;
      color: #e8e8e8;
      font-family: Inter, system-ui, sans-serif;
    }

    .ct-storybook-frame {
      box-sizing: border-box;
      min-height: calc(100vh - 32px);
      border: 1px solid #3f4652;
      background: #101216;
      overflow: auto;
    }

    .ct-storybook-surface[data-kind="layout"] .ct-storybook-frame {
      border: 0;
      background: transparent;
    }

    .ct-storybook-frame > .component-container,
    .ct-storybook-frame > .component-container.terminal,
    .ct-storybook-frame > .terminal,
    .ct-storybook-frame > .panel,
    .ct-storybook-frame > .isonim-app-shell {
      min-height: calc(100vh - 34px);
    }

    .ct-storybook-surface pre {
      margin: 0;
      font: 13px/1.45 "JetBrains Mono", "SFMono-Regular", Consolas, monospace;
      white-space: pre-wrap;
    }

    .ct-storybook-surface .ansi-bright-green-fg { color: #7ee787; }
    .ct-storybook-surface .ansi-bright-cyan-fg { color: #67e8f9; }
    .ct-storybook-surface .ansi-bright-yellow-fg { color: #facc15; }
    .ct-storybook-surface .ansi-bright-red-fg { color: #ff7b72; }
  `;
  container.appendChild(style);
}

function renderSurface(kind, name, fixture = "populated") {
  const container = document.createElement("div");
  container.className = "ct-storybook-surface";
  container.dataset.kind = kind;
  container.dataset.surface = name;
  injectSurfaceStyles(container);

  const frame = document.createElement("div");
  frame.className = "ct-storybook-frame";
  container.appendChild(frame);

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
