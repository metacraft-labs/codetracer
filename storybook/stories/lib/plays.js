// Named play checks for CodeTracer stories, by the name a story declaration's
// `check` field gives (`src/frontend/stories/codetracer_stories.nim`). Each
// runs after `./csf.js`'s default check and asserts what the story is for.
import { expect } from "@storybook/test";
import { tick } from "./surfaces.js";

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

// --- Agent Harbor ---------------------------------------------------------
// The fleet stories run over the private capture of a real fleet where the
// build can see it and over the public synthetic set otherwise
// (nim-agents-isonim-viewmodels' fixture_source.nim); these hold for both.

const fleetRows = (el) => el.querySelectorAll(".ah-fleet-row");

function fleetCheck(assert) {
  return async ({ canvasElement }) => {
    await waitFor(canvasElement, ".agent-harbor-fleet");
    await assert(canvasElement);
  };
}

// --- Terminal output ------------------------------------------------------

function terminalCheck(assert) {
  return async ({ canvasElement }) => assert(canvasElement);
}

export const plays = {
  "agent-harbor-fleet-snapshot": fleetCheck(async (el) => {
    await waitFor(el, ".ah-fleet-row");
    expect(fleetRows(el).length).toBeGreaterThan(40);
    expect(el.querySelectorAll(".ah-fleet-filter").length).toBe(6);
    expect(el.querySelector(".ah-fleet-filter-active")?.textContent).toContain("All");
    // Sessions waiting for a person come first.
    expect(fleetRows(el)[0].classList.contains("ah-fleet-cat-needs-input")).toBe(true);
    // The effective status: a session waiting for a person says so (INV-P2-14).
    expect(fleetRows(el)[0].querySelector(".ah-fleet-status-label")?.textContent).toMatch(/^needs input/);
    // Rows can be told apart even where the server withholds every prompt.
    const titles = new Set([...fleetRows(el)].map((r) => r.querySelector(".ah-fleet-row-title")?.textContent));
    expect(titles.size).toBeGreaterThan(fleetRows(el).length / 2);
    // The header names the snapshot the rows come from.
    expect(el.querySelector(".ah-fleet-source")?.textContent).toMatch(/fleet.*UTC/);
  }),
  "agent-harbor-fleet-needs-input": fleetCheck(async (el) => {
    await waitFor(el, ".ah-fleet-row");
    for (const row of fleetRows(el)) expect(row.classList.contains("ah-fleet-cat-needs-input")).toBe(true);
    expect(el.querySelector(".ah-fleet-filter-active")?.textContent).toContain("Needs input");
  }),
  "agent-harbor-fleet-failed": fleetCheck(async (el) => {
    await waitFor(el, ".ah-fleet-row");
    for (const row of fleetRows(el)) expect(row.classList.contains("ah-fleet-cat-failed")).toBe(true);
  }),
  "agent-harbor-fleet-selected": fleetCheck(async (el) => {
    await waitFor(el, ".ah-fleet-row-selected");
    expect(el.querySelectorAll(".ah-fleet-row-selected").length).toBe(1);
  }),
  "agent-harbor-fleet-loading": fleetCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-loading")?.textContent).toContain("Loading sessions");
    expect(fleetRows(el).length).toBe(0);
  }),
  "agent-harbor-fleet-error": fleetCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-error-message")?.textContent).toContain("connection refused");
    expect(el.querySelector(".ah-fleet-retry")).toBeTruthy();
  }),
  "agent-harbor-fleet-empty": fleetCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-overlay")?.textContent).toContain("No sessions");
    expect(fleetRows(el).length).toBe(0);
  }),

  "terminal-output-populated": terminalCheck((el) => {
    expect(el.querySelector(".isonim-terminal-output")).toBeTruthy();
    expect(el.querySelectorAll(".terminal-line").length).toBe(3);
    // The active session tab; the first `.active` is the view toggle ("Lines").
    expect([...el.querySelectorAll(".active")].map((e) => e.textContent).join(" | ")).toContain("noir-space-ship");
  }),
  "terminal-output-empty": terminalCheck((el) => {
    expect(el.querySelectorAll(".terminal-line").length).toBe(0);
    expect(el.querySelector(".empty-overlay")?.textContent).toContain("does not print anything");
  }),
  "terminal-output-loading": terminalCheck((el) => {
    expect(el.querySelector(".empty-overlay")?.textContent).toContain("Loading record output");
  }),

  "frame-viewer": async ({ canvasElement }) => {
    const image = canvasElement.querySelector(".frame-viewer-image");
    await expect(image).toBeTruthy();
    await expect(image).toHaveAttribute("src", /data:image\/svg\+xml/);
    await expect(canvasElement.querySelector(".frame-viewer-draw-call")).toBeTruthy();

    const firstSrc = image.getAttribute("src");
    const next = canvasElement.querySelector(".frame-viewer-next-frame");
    next.click();
    await tick();
    await expect(image.getAttribute("src")).not.toBe(firstSrc);
  },
};
