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

// Sessions as tabs (the caption bar's strip, the sidebar and docked list),
// initiatives and initiative progress. Over the working set of the fixture
// set the build embedded, or an invented one for overflow and long names.

const tabsOf = (el) => el.querySelectorAll(".ah-tab-strip .ah-tab");
const marks = ["needs-input", "idle", "running", "queued", "failed", "ended"];
const attentionOf = (node) => marks.find((m) => node.classList.contains(`ah-att-${m}`));

function hostCheck(selector, assert) {
  return async ({ canvasElement }) => {
    await waitFor(canvasElement, selector);
    await assert(canvasElement);
  };
}

const tabsCheck = (assert) => hostCheck(".ah-tab-strip", assert);
const listCheck = (assert) => hostCheck(".ah-session-list", assert);
const initiativesCheck = (assert) => hostCheck(".agent-harbor-initiatives", assert);
const progressCheck = (assert) => hostCheck(".agent-harbor-progress", assert);
const initiativeTabsCheck = (assert) => hostCheck(".ah-initiative-tab-bar", assert);

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

  "agent-harbor-fleet-filtered-empty": fleetCheck(async (el) => {
    await waitFor(el, ".ah-fleet-filter-active");
    expect(el.querySelector(".ah-fleet-filter-active")?.textContent).toContain("Queued");
    expect(el.querySelector(".ah-fleet-overlay")?.textContent).toContain("No session in this category");
    expect(fleetRows(el).length).toBe(0);
  }),
  "agent-harbor-fleet-expanded": fleetCheck(async (el) => {
    await waitFor(el, ".ah-fleet-row");
    // One row unfolded, every other row one activity line.
    const lines = [...fleetRows(el)].map((r) => r.querySelectorAll(".ah-fleet-activity-line").length);
    expect(lines.filter((n) => n > 1).length).toBe(1);
    expect(el.querySelector(".ah-fleet-activity-more")?.textContent).toBeTruthy();
  }),

  "agent-harbor-session-tabs": tabsCheck(async (el) => {
    await waitFor(el, ".ah-tab");
    expect(tabsOf(el).length).toBeGreaterThan(0);
    expect(el.querySelectorAll(".ah-tab-strip .session-tab.active").length).toBe(1);
    for (const tab of tabsOf(el)) expect(attentionOf(tab)).toBeTruthy();
    expect(el.querySelector(".ah-tab-strip .session-tab-add")).toBeTruthy();
  }),
  "agent-harbor-session-tabs-active": tabsCheck(async (el) => {
    await waitFor(el, ".session-tab-overflow-item");
    // The active tab is drawn in the row although it is late in the strip.
    const active = el.querySelector(".ah-tab-strip .session-tab.active");
    expect(active).toBeTruthy();
    expect(el.querySelector(".ah-tab-strip.overflow-open")).toBeTruthy();
    expect(el.querySelectorAll(".session-tab-overflow-item.active").length).toBe(0);
  }),
  "agent-harbor-session-tabs-multi": tabsCheck(async (el) => {
    await waitFor(el, ".ah-tab");
    expect(el.querySelector(".ah-tab-strip.ah-tab-strip-wrap")).toBeTruthy();
    expect(el.querySelectorAll(".session-tab-overflow-item").length).toBe(0);
    const tops = new Set([...tabsOf(el)].map((t) => Math.round(t.getBoundingClientRect().top)));
    expect(tops.size).toBeGreaterThan(1);
  }),
  "agent-harbor-session-tabs-overflow": tabsCheck(async (el) => {
    await waitFor(el, ".ah-tab");
    const shown = tabsOf(el).length;
    const menu = el.querySelectorAll(".session-tab-overflow-item").length;
    expect(shown + menu).toBe(40);
    expect(menu).toBeGreaterThan(0);
  }),
  "agent-harbor-session-tabs-multi-overflow": tabsCheck(async (el) => {
    await waitFor(el, ".ah-tab");
    expect(tabsOf(el).length).toBe(40);
  }),
  "agent-harbor-session-tabs-focus": tabsCheck(async (el) => {
    await waitFor(el, ".ah-tab-in-focus");
    expect(el.querySelector(".ah-tab-strip .session-tab.active.ah-tab-in-focus")).toBeTruthy();
  }),
  "agent-harbor-session-tabs-empty": tabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-empty")).toBeTruthy();
    expect(tabsOf(el).length).toBe(0);
  }),
  "agent-harbor-session-tabs-loading": tabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-loading")?.textContent).toContain("Loading sessions");
  }),
  "agent-harbor-session-tabs-error": tabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-error")?.textContent).toContain("connection refused");
    expect(el.querySelector(".ah-tab-retry")).toBeTruthy();
  }),

  "agent-harbor-initiative-tabs": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-initiative-tab");
    expect(el.querySelectorAll(".ah-initiative-tab").length).toBeGreaterThan(0);
    for (const tab of el.querySelectorAll(".ah-initiative-tab")) {
      expect(tab.querySelector(".ah-tab-progress")?.textContent).toMatch(/^\d+\/\d+$/);
      expect([...tab.classList].some((c) => c.startsWith("ah-ist-"))).toBe(true);
    }
    expect(el.querySelectorAll(".ah-initiative-tab.active").length).toBe(1);
  }),
  "agent-harbor-initiative-tabs-popup": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-initiative-popup");
    expect(el.querySelector(".ah-initiative-popup .ah-popup-headline")?.textContent).toMatch(/milestone/);
  }),
  "agent-harbor-initiative-tabs-elsewhere": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-elsewhere-menu");
    expect(el.querySelector(".ah-elsewhere")?.textContent).toMatch(/^\[\d+ agent harbor sessions?\]$/);
    expect(el.querySelectorAll(".ah-elsewhere-menu .session-tab-overflow-item").length).toBeGreaterThan(0);
    // Drawn, not only in the DOM: the bar clips what overflows it unless a
    // menu is open.
    const menu = el.querySelector(".ah-elsewhere-menu");
    expect(menu.getBoundingClientRect().height).toBeGreaterThan(0);
    expect(getComputedStyle(el.querySelector(".ah-initiative-tab-bar")).overflow).toBe("visible");
  }),
  "agent-harbor-initiative-tabs-inbox": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-inbox");
    expect(el.querySelector(".ah-inbox-position")?.textContent).toMatch(/of \d+|waiting|empty/);
  }),
  "agent-harbor-initiative-tabs-recordings": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-rec-button");
    expect(el.querySelectorAll(".ah-rec-button").length).toBe(9);
    expect(el.querySelector(".ah-rec-more")?.textContent).toBe("+3");
    expect(el.querySelector(".ah-rec-loading")).toBeTruthy();
    expect(el.querySelector(".ah-rec-failed")?.textContent).toMatch(/✕$/);
    expect(el.querySelector(".ah-rec-missing")?.textContent).toMatch(/\?$/);
  }),
  "agent-harbor-initiative-tabs-empty": initiativeTabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-empty")?.textContent).toContain("No initiative");
  }),
  "agent-harbor-initiative-tabs-loading": initiativeTabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-loading")?.textContent).toContain("Loading");
  }),
  "agent-harbor-initiative-tabs-error": initiativeTabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-error")?.textContent).toContain("connection refused");
  }),
  "agent-harbor-session-list-tree": listCheck(async (el) => {
    await waitFor(el, ".ah-session-group-header");
    expect(el.querySelectorAll(".ah-session-group-fold").length).toBeGreaterThan(1);
    // Folded nodes keep their header and drop their rows.
    const groups = [...el.querySelectorAll(".ah-session-group")];
    expect(groups.filter((g) => !g.querySelector(".ah-session-group-rows")).length).toBe(2);
  }),
  "agent-harbor-session-list": listCheck(async (el) => {
    await waitFor(el, ".ah-session-row");
    expect(el.querySelectorAll(".ah-session-row-active").length).toBe(1);
    for (const row of el.querySelectorAll(".ah-session-row")) expect(attentionOf(row)).toBeTruthy();
  }),
  "agent-harbor-session-list-collapsed": listCheck(async (el) => {
    await waitFor(el, ".ah-session-row-rail");
    expect(el.querySelector(".ah-session-list-collapsed")).toBeTruthy();
    expect(el.querySelectorAll(".ah-session-row-title").length).toBe(0);
  }),
  "agent-harbor-session-list-empty": listCheck(async (el) => {
    expect(el.querySelector(".ah-session-list-overlay")?.textContent).toContain("No sessions");
  }),
  "agent-harbor-session-list-loading": listCheck(async (el) => {
    expect(el.querySelector(".ah-session-list-loading")?.textContent).toContain("Loading sessions");
  }),
  "agent-harbor-session-list-error": listCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-error-message")?.textContent).toContain("connection refused");
  }),

  "agent-harbor-initiatives": initiativesCheck(async (el) => {
    await waitFor(el, ".ah-initiative-row");
    expect(el.querySelectorAll(".ah-initiative-row").length).toBeGreaterThan(1);
    for (const row of el.querySelectorAll(".ah-initiative-row")) {
      expect(row.querySelector(".ah-initiative-progress-text")?.textContent).toMatch(/^\d+\/\d+ · \d+%$/);
    }
  }),
  "agent-harbor-initiatives-selected": initiativesCheck(async (el) => {
    await waitFor(el, ".ah-initiative-row-selected");
    expect(el.querySelectorAll(".ah-initiative-row-selected").length).toBe(1);
    expect(el.querySelector(".ah-initiative-row-selected .ah-initiative-session")).toBeTruthy();
  }),
  "agent-harbor-initiatives-empty": initiativesCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-overlay")?.textContent).toContain("No initiative");
  }),
  "agent-harbor-initiatives-loading": initiativesCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-loading")?.textContent).toContain("Loading initiatives");
  }),
  "agent-harbor-initiatives-error": initiativesCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-error-message")?.textContent).toContain("connection refused");
  }),

  "agent-harbor-progress": progressCheck(async (el) => {
    await waitFor(el, ".ah-milestone");
    expect(el.querySelectorAll(".ah-progress-group").length).toBeGreaterThan(0);
    expect(el.querySelectorAll(".ah-milestone-current").length).toBeLessThanOrEqual(1);
  }),
  "agent-harbor-progress-blocked": progressCheck(async (el) => {
    await waitFor(el, ".ah-ms-blocked");
    expect(el.querySelector(".ah-ms-group-blocked")).toBeTruthy();
  }),
  "agent-harbor-progress-empty": progressCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-overlay")?.textContent).toContain("Select an initiative");
  }),
  "agent-harbor-progress-loading": progressCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-loading")?.textContent).toContain("Loading");
  }),
  "agent-harbor-progress-error": progressCheck(async (el) => {
    expect(el.querySelector(".ah-fleet-error-message")?.textContent).toContain("connection refused");
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
