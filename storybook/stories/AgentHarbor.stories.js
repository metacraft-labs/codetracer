import { expect } from "@storybook/test";
import { story } from "./CodeTracerSurfaces.stories.js";

// CodeTracer as an Agent Harbor front-end: prototypes of the panels that show
// an Agent Harbor fleet. Every story mounts the production IsoNim view
// (src/frontend/viewmodel/views/isonim_agent_harbor_*.nim) over a real
// viewmodel from nim-agents-isonim-viewmodels, fed through that package's
// data-source seam: the fixture set for every populated state, and the seam's
// state sources for loading, error and empty. The fixture set is the private
// capture of a real fleet where the build can see it, and the public
// synthetic set otherwise (nim-agents-isonim-viewmodels' fixture_source.nim);
// the assertions below hold for both. Inventory items: INV-P2-01, INV-P2-12.

const meta = {
  title: "CodeTracer/Agent Harbor",
  includeStories: /^[A-Z]/,
  parameters: {
    layout: "fullscreen",
  },
};

export default meta;

function waitFor(canvasElement, selector, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const poll = () => {
      const found = canvasElement.querySelector(selector);
      if (found) return resolve(found);
      if (Date.now() - started > timeoutMs) return reject(new Error(`no ${selector}`));
      setTimeout(poll, 25);
    };
    poll();
  });
}

function fleetStory(fixture, storyName, assert) {
  const surface = story("panel", "agent-harbor-fleet", fixture, storyName);
  return {
    ...surface,
    play: async (context) => {
      await surface.play(context);
      await waitFor(context.canvasElement, ".agent-harbor-fleet");
      await assert(context.canvasElement);
    },
  };
}

const rows = (el) => el.querySelectorAll(".ah-fleet-row");

export const FleetSnapshot = fleetStory("snapshot", "Fleet Snapshot", async (el) => {
  await waitFor(el, ".ah-fleet-row");
  expect(rows(el).length).toBeGreaterThan(40);
  expect(el.querySelectorAll(".ah-fleet-filter").length).toBe(6);
  expect(el.querySelector(".ah-fleet-filter-active")?.textContent).toContain("All");
  // Sessions waiting for a person come first.
  expect(rows(el)[0].classList.contains("ah-fleet-cat-needs-input")).toBe(true);
  // The effective status: a session waiting for a person says so (INV-P2-14).
  expect(rows(el)[0].querySelector(".ah-fleet-status-label")?.textContent).toMatch(/^needs input/);
  // Rows can be told apart even where the server withholds every prompt.
  const titles = new Set([...rows(el)].map((r) => r.querySelector(".ah-fleet-row-title")?.textContent));
  expect(titles.size).toBeGreaterThan(rows(el).length / 2);
  // The header names the snapshot the rows come from.
  expect(el.querySelector(".ah-fleet-source")?.textContent).toMatch(/fleet.*UTC/);
});

export const FleetNeedsInput = fleetStory("needs-input", "Fleet: Needs Input", async (el) => {
  await waitFor(el, ".ah-fleet-row");
  for (const row of rows(el)) expect(row.classList.contains("ah-fleet-cat-needs-input")).toBe(true);
  expect(el.querySelector(".ah-fleet-filter-active")?.textContent).toContain("Needs input");
});

export const FleetFailed = fleetStory("failed", "Fleet: Failed", async (el) => {
  await waitFor(el, ".ah-fleet-row");
  for (const row of rows(el)) expect(row.classList.contains("ah-fleet-cat-failed")).toBe(true);
});

export const FleetSelected = fleetStory("selected", "Fleet: Selected Session", async (el) => {
  await waitFor(el, ".ah-fleet-row-selected");
  expect(el.querySelectorAll(".ah-fleet-row-selected").length).toBe(1);
});

export const FleetLoading = fleetStory("loading", "Fleet: Loading", async (el) => {
  expect(el.querySelector(".ah-fleet-loading")?.textContent).toContain("Loading sessions");
  expect(rows(el).length).toBe(0);
});

export const FleetError = fleetStory("error", "Fleet: Error", async (el) => {
  expect(el.querySelector(".ah-fleet-error-message")?.textContent).toContain("connection refused");
  expect(el.querySelector(".ah-fleet-retry")).toBeTruthy();
});

export const FleetEmpty = fleetStory("empty", "Fleet: Empty", async (el) => {
  expect(el.querySelector(".ah-fleet-overlay")?.textContent).toContain("No sessions");
  expect(rows(el).length).toBe(0);
});
