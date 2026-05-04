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
      font-size: 16px;
      line-height: 24px;
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

    .ct-storybook-default-layout {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-height: 0;
      font-size: 16px;
      line-height: 24px;
    }

    .ct-storybook-default-layout .lm_row,
    .ct-storybook-default-layout .lm_column {
      box-sizing: border-box;
      display: flex;
      min-width: 0;
      min-height: 0;
      overflow: hidden;
    }

    .ct-storybook-default-layout > .lm_row {
      width: 100%;
      height: 100%;
      flex-direction: row;
      gap: 4px;
    }

    .ct-storybook-default-layout .lm_column {
      flex-direction: column;
      gap: 4px;
    }

    .ct-storybook-layout-sidebar {
      flex: 0 0 14%;
    }

    .ct-storybook-layout-editor {
      flex: 0 0 33%;
    }

    .ct-storybook-layout-right {
      flex: 1 1 53%;
    }

    .ct-storybook-layout-right-top {
      flex: 1 1 50%;
      flex-direction: row;
      gap: 4px;
    }

    .ct-storybook-layout-right-top > .lm_column {
      flex: 1 1 50%;
    }

    .ct-storybook-layout-right-bottom {
      flex: 1 1 50%;
    }

    .ct-storybook-default-layout .lm_stack {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      min-width: 0;
      min-height: 0;
      overflow: hidden;
    }

    .ct-storybook-default-layout .lm_header {
      box-sizing: border-box;
      flex: 0 0 32px;
      height: 32px !important;
      min-height: 32px;
      overflow: visible;
    }

    .ct-storybook-default-layout .lm_items {
      box-sizing: border-box;
      flex: 1 1 auto;
      min-height: 0;
      overflow: hidden;
    }

    .ct-storybook-default-layout .lm_items > div,
    .ct-storybook-default-layout .lm_content,
    .ct-storybook-default-layout .ct-storybook-panel-content {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-width: 0;
      min-height: 0;
    }

    .ct-storybook-default-layout .ct-storybook-panel-content > .component-container,
    .ct-storybook-default-layout .ct-storybook-panel-content > .build-panel,
    .ct-storybook-default-layout .ct-storybook-panel-content > .panel {
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      min-width: 0;
      min-height: 0;
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

function createGoldenStack(title) {
  const stack = document.createElement("div");
  stack.className = "lm_item lm_stack";

  const header = document.createElement("section");
  header.className = "lm_header";

  const tabs = document.createElement("section");
  tabs.className = "lm_tabs";

  const tab = document.createElement("div");
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

  const items = document.createElement("section");
  items.className = "lm_items";

  const item = document.createElement("div");
  const content = document.createElement("div");
  content.className = "lm_content";
  const mount = document.createElement("div");
  mount.className = "ct-storybook-panel-content";
  content.appendChild(mount);
  item.appendChild(content);
  items.appendChild(item);
  stack.appendChild(header);
  stack.appendChild(items);

  return { stack, mount };
}

function appendDefaultDebugLayout(frame) {
  const root = document.createElement("div");
  root.className = "lm_goldenlayout lm_item lm_root ct-storybook-default-layout";

  const row = document.createElement("div");
  row.className = "lm_item lm_row";

  const leftColumn = document.createElement("div");
  leftColumn.className = "lm_item lm_column ct-storybook-layout-sidebar";

  const editorColumn = document.createElement("div");
  editorColumn.className = "lm_item lm_column ct-storybook-layout-editor";

  const rightColumn = document.createElement("div");
  rightColumn.className = "lm_item lm_column ct-storybook-layout-right";

  const rightTop = document.createElement("div");
  rightTop.className = "lm_item lm_row ct-storybook-layout-right-top";

  const rightTopLeft = document.createElement("div");
  rightTopLeft.className = "lm_item lm_column";

  const rightTopRight = document.createElement("div");
  rightTopRight.className = "lm_item lm_column";

  const rightBottom = document.createElement("div");
  rightBottom.className = "lm_item lm_column ct-storybook-layout-right-bottom";

  const panels = [
    { parent: leftColumn, title: "FILESYSTEM", name: "filesystem" },
    { parent: editorColumn, title: "src/main.nr", name: "editor" },
    { parent: rightTopLeft, title: "SCRATCHPAD", name: "scratchpad" },
    { parent: rightTopRight, title: "CALLTRACE", name: "calltrace" },
    { parent: rightBottom, title: "EVENT LOG", name: "event-log" },
    { parent: rightBottom, title: "TERMINAL OUTPUT", name: "terminal-output" },
  ];

  const mounts = [];
  for (const panel of panels) {
    const { stack, mount } = createGoldenStack(panel.title);
    stack.dataset.panelName = panel.name;
    panel.parent.appendChild(stack);
    mounts.push({ name: panel.name, mount });
  }

  rightTop.appendChild(rightTopLeft);
  rightTop.appendChild(rightTopRight);
  rightColumn.appendChild(rightTop);
  rightColumn.appendChild(rightBottom);
  row.appendChild(leftColumn);
  row.appendChild(editorColumn);
  row.appendChild(rightColumn);
  root.appendChild(row);
  frame.appendChild(root);

  return mounts;
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

function renderDefaultDebugLayout(container) {
  const frame = createAppShell(container, "layout", "default-debug");
  const mounts = appendDefaultDebugLayout(frame);

  ensureComponentsLoaded().then(() => {
    const disposes = mounts.map(({ name, mount }) =>
      mountCodeTracerStory(mount, "panel", name, "populated"),
    );
    container.__dispose = () => {
      for (const dispose of disposes) {
        if (typeof dispose === "function") dispose();
      }
    };
  });
}

function renderSurface(kind, name, fixture = "populated") {
  const container = document.createElement("div");
  container.className = "ct-storybook-surface";
  container.dataset.kind = kind;
  container.dataset.surface = name;
  injectSurfaceStyles(container);

  if (kind === "layout" && name === "default-debug") {
    renderDefaultDebugLayout(container);
    return container;
  }

  const frame = createAppShell(container, kind, name);

  ensureComponentsLoaded().then(() => {
    const dispose = mountCodeTracerStory(frame, kind, name, fixture);
    container.__dispose = dispose;
  });

  return container;
}

export function story(kind, name, fixture = "populated", storyName = null) {
  return {
    name: storyName ?? titleize(name),
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
  title: "CodeTracer/Panels",
  includeStories: /^[A-Z]/,
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const AgentActivity = story("panel", "agent-activity", "populated", "Agent Activity");
export const AgentActivityDeepReview = story(
  "panel",
  "agent-activity-deepreview",
  "populated",
  "Agent Activity Deep Review",
);
export const AgentWorkspace = story("panel", "agent-workspace", "populated", "Agent Workspace");
export const Build = story("panel", "build", "populated", "Build");
export const Calltrace = story("panel", "calltrace", "populated", "Calltrace");
export const CalltraceEditor = story("panel", "calltrace-editor", "populated", "Calltrace Editor");
export const CommandPalette = story("panel", "command-palette", "populated", "Command Palette");
export const DebugControls = story("panel", "debug-controls", "populated", "Debug Controls");
export const DeepReview = story("panel", "deepreview", "populated", "Deep Review");
export const Editor = story("panel", "editor", "populated", "Editor");
export const Errors = story("panel", "errors", "populated", "Errors");
export const EventLog = story("panel", "event-log", "populated", "Event Log");
export const Filesystem = story("panel", "filesystem", "populated", "Filesystem");
export const Flow = story("panel", "flow", "populated", "Flow");
export const LowLevelCode = story("panel", "low-level-code", "populated", "Low Level Code");
export const NoSource = story("panel", "no-source", "populated", "No Source");
export const PointList = story("panel", "point-list", "populated", "Point List");
export const Repl = story("panel", "repl", "populated", "Repl");
export const RequestPanel = story("panel", "request-panel", "populated", "Request Panel");
export const Scratchpad = story("panel", "scratchpad", "populated", "Scratchpad");
export const Search = story("panel", "search", "populated", "Search");
export const SearchResults = story("panel", "search-results", "populated", "Search Results");
export const Shell = story("panel", "shell", "populated", "Shell");
export const State = story("panel", "state", "populated", "State");
export const StepList = story("panel", "step-list", "populated", "Step List");
export const TerminalOutput = story("panel", "terminal-output", "populated", "Terminal Output");
export const Timeline = story("panel", "timeline", "populated", "Timeline");
export const TraceLog = story("panel", "trace-log", "populated", "Trace Log");
export const Vcs = story("panel", "vcs", "populated", "VCS");
export const WelcomeScreen = story("panel", "welcome-screen", "populated", "Welcome Screen");
