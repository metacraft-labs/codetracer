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

    .ct-storybook-terminal .component-container.terminal {
      height: 100vh;
      overflow: auto;
    }
  `;
  container.appendChild(style);
}

function renderTerminalOutput(fixture) {
  const container = document.createElement("div");
  container.className = "ct-storybook-terminal";
  injectTerminalStyles(container);

  const mountPoint = document.createElement("div");
  container.appendChild(mountPoint);

  ensureComponentsLoaded().then(() => {
    const dispose = mountTerminalOutputPanel(
      mountPoint,
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
