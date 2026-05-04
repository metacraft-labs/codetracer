import { expect } from "@storybook/test";

let loadPromise = null;

function ensureComponentsLoaded() {
  if (typeof mountTerminalOutputPanel !== "undefined") {
    return Promise.resolve();
  }

  if (!loadPromise) {
    loadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = "./dist/components.js";
      script.onload = () => resolve();
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

function injectTerminalStyles(container) {
  const style = document.createElement("style");
  style.textContent = `
    .ct-storybook-terminal {
      box-sizing: border-box;
      min-height: 100vh;
    }

    .ct-storybook-terminal #root-container {
      top: 0 !important;
      height: 100vh !important;
    }

    .ct-storybook-terminal #main {
      display: flex;
      flex-wrap: nowrap;
      width: 100%;
      min-height: 0;
    }

    .ct-storybook-terminal .ct-storybook-golden-panel {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      width: 100%;
      min-width: 0;
      min-height: 0;
      height: 100%;
    }

    .ct-storybook-terminal .lm_stack {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      flex-direction: column;
      min-width: 0;
      min-height: 0;
      width: 100%;
      height: 100%;
    }

    .ct-storybook-terminal .lm_header {
      box-sizing: border-box;
      display: flex;
      align-items: flex-end;
      flex: 0 0 30px;
      min-height: 30px;
      height: 30px !important;
      overflow: visible;
    }

    .ct-storybook-terminal .lm_tabs {
      box-sizing: border-box;
      align-items: flex-end;
      height: 30px;
      margin: 0;
      padding: 0 30px 0 0;
    }

    .ct-storybook-terminal .lm_controls {
      box-sizing: border-box;
      display: flex !important;
      align-items: center !important;
      height: 30px !important;
      top: 0 !important;
      right: 0 !important;
    }

    .ct-storybook-terminal .lm_controls > * {
      box-sizing: border-box;
      width: 16px !important;
      height: 16px !important;
      margin-top: 0 !important;
    }

    .ct-storybook-terminal .lm_items,
    .ct-storybook-terminal .lm_content,
    .ct-storybook-terminal .ct-storybook-panel-content {
      box-sizing: border-box;
      display: flex;
      flex: 1 1 100%;
      min-width: 0;
      min-height: 0;
      width: 100%;
    }

    .ct-storybook-terminal .component-container.terminal {
      box-sizing: border-box;
      flex: 1 1 100%;
      width: 100%;
      min-width: 0;
      height: 100vh;
      overflow: auto;
    }
  `;
  container.appendChild(style);
}

function createGoldenPanelHost(frame) {
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

  const title = document.createElement("span");
  title.className = "lm_title";
  title.textContent = "Terminal Output";
  tab.appendChild(title);

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
  const mountPoint = document.createElement("div");
  mountPoint.className = "ct-storybook-panel-content";
  content.appendChild(mountPoint);
  items.appendChild(content);
  stack.appendChild(header);
  stack.appendChild(items);
  layout.appendChild(stack);
  frame.appendChild(layout);

  return mountPoint;
}

function renderTerminalOutput(fixture) {
  const container = document.createElement("div");
  container.className = "ct-storybook-terminal";
  injectTerminalStyles(container);

  const rootContainer = document.createElement("div");
  rootContainer.id = "root-container";
  const layoutRow = document.createElement("div");
  layoutRow.id = "auto-hide-layout-row";
  const root = document.createElement("div");
  root.id = "ROOT";
  const session = document.createElement("div");
  session.id = "session-container-0";
  session.className = "session-container";
  const mountPoint = document.createElement("section");
  mountPoint.id = "main";
  mountPoint.className = "ct-storybook-frame";
  const panelMount = createGoldenPanelHost(mountPoint);
  session.appendChild(mountPoint);
  root.appendChild(session);
  const leftStrip = document.createElement("div");
  leftStrip.id = "auto-hide-strip-left";
  layoutRow.appendChild(leftStrip);
  layoutRow.appendChild(root);
  const rightStrip = document.createElement("div");
  rightStrip.id = "auto-hide-strip-right";
  layoutRow.appendChild(rightStrip);
  rootContainer.appendChild(layoutRow);
  container.appendChild(rootContainer);

  ensureComponentsLoaded().then(() => {
    const dispose = mountTerminalOutputPanel(
      panelMount,
      fixture,
    );
    container.__dispose = dispose;
  });

  return container;
}

const meta = {
  title: "CodeTracer/Panels/Terminal Output",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const Populated = {
  render: () => renderTerminalOutput("populated"),
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    expect(canvasElement.querySelector(".isonim-terminal-output")).toBeTruthy();
    expect(canvasElement.querySelectorAll(".terminal-line").length).toBe(3);
    expect(canvasElement.querySelector(".active")?.textContent).toContain(
      "noir-space-ship",
    );
  },
};

export const Empty = {
  render: () => renderTerminalOutput("empty"),
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    expect(canvasElement.querySelectorAll(".terminal-line").length).toBe(0);
    expect(canvasElement.querySelector(".empty-overlay")?.textContent).toContain(
      "does not print anything",
    );
  },
};

export const Loading = {
  render: () => renderTerminalOutput("loading"),
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    expect(canvasElement.querySelector(".empty-overlay")?.textContent).toContain(
      "Loading record output",
    );
  },
};
