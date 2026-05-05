import { expect } from "@storybook/test";
import { story } from "./CodeTracerSurfaces.stories.js";

const meta = {
  title: "CodeTracer/Compatibility/Terminal Output",
  includeStories: /^[A-Z]/,
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

function terminalStory(fixture, storyName, assert) {
  const surface = story("panel", "terminal-output", fixture, storyName);
  return {
    ...surface,
    play: async (context) => {
      await surface.play(context);
      assert(context.canvasElement);
    },
  };
}

export const Populated = terminalStory("demo", "Populated", (canvasElement) => {
  expect(canvasElement.querySelector(".isonim-terminal-output")).toBeTruthy();
  expect(canvasElement.querySelectorAll(".terminal-line").length).toBe(3);
  expect(canvasElement.querySelector(".active")?.textContent).toContain("noir-space-ship");
});

export const Empty = terminalStory("empty", "Empty", (canvasElement) => {
  expect(canvasElement.querySelectorAll(".terminal-line").length).toBe(0);
  expect(canvasElement.querySelector(".empty-overlay")?.textContent).toContain(
    "does not print anything",
  );
});

export const Loading = terminalStory("loading", "Loading", (canvasElement) => {
  expect(canvasElement.querySelector(".empty-overlay")?.textContent).toContain(
    "Loading record output",
  );
});
