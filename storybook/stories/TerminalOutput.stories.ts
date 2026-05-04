import type { Meta, StoryObj } from "@storybook/html";
import { expect } from "@storybook/test";

declare global {
  function mountTerminalOutputPanel(
    container: Element,
    fixture: string,
  ): () => void;
}

let loadPromise: Promise<void> | null = null;

function ensureComponentsLoaded(): Promise<void> {
  if (typeof mountTerminalOutputPanel !== "undefined") {
    return Promise.resolve();
  }

  if (!loadPromise) {
    loadPromise = new Promise<void>((resolve, reject) => {
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

function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function injectTerminalStyles(container: HTMLElement): void {
  const style = document.createElement("style");
  style.textContent = `
    .ct-storybook-terminal {
      box-sizing: border-box;
      min-height: 100vh;
      padding: 16px;
      background: #161616;
      color: #e8e8e8;
      font-family: Inter, system-ui, sans-serif;
    }

    .ct-storybook-terminal .component-container.terminal {
      height: calc(100vh - 32px);
      overflow: auto;
      border: 1px solid #3f4652;
      background: #0f1115;
    }

    .ct-storybook-terminal pre {
      margin: 0;
      padding: 12px;
      font: 13px/1.45 "JetBrains Mono", "SFMono-Regular", Consolas, monospace;
      white-space: pre-wrap;
    }

    .ct-storybook-terminal .terminal-line {
      min-height: 18px;
    }

    .ct-storybook-terminal .terminal-line > div {
      display: inline;
      cursor: pointer;
    }

    .ct-storybook-terminal .past {
      color: #8e98a8;
    }

    .ct-storybook-terminal .active {
      color: #f3f4f6;
      background: #334155;
    }

    .ct-storybook-terminal .future {
      color: #5eead4;
    }

    .ct-storybook-terminal .empty-overlay {
      padding: 12px;
      color: #a7b0bd;
      font: 13px/1.45 "JetBrains Mono", "SFMono-Regular", Consolas, monospace;
    }

    .ct-storybook-terminal .ansi-bright-green-fg { color: #7ee787; }
    .ct-storybook-terminal .ansi-bright-cyan-fg { color: #67e8f9; }
    .ct-storybook-terminal .ansi-bright-yellow-fg { color: #facc15; }
  `;
  container.appendChild(style);
}

function renderTerminalOutput(fixture: string): HTMLElement {
  const container = document.createElement("div");
  container.className = "ct-storybook-terminal";
  injectTerminalStyles(container);

  const mountPoint = document.createElement("div");
  container.appendChild(mountPoint);

  ensureComponentsLoaded().then(() => {
    const dispose = mountTerminalOutputPanel(
      mountPoint as unknown as Element,
      fixture,
    );
    (container as any).__dispose = dispose;
  });

  return container;
}

const meta: Meta = {
  title: "CodeTracer/Panels/Terminal Output",
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

export const Populated: StoryObj = {
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

export const Empty: StoryObj = {
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

export const Loading: StoryObj = {
  render: () => renderTerminalOutput("loading"),
  play: async ({ canvasElement }) => {
    await ensureComponentsLoaded();
    await tick();

    expect(canvasElement.querySelector(".empty-overlay")?.textContent).toContain(
      "Loading record output",
    );
  },
};
