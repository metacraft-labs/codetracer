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

// Wait until `ready()` answers true: for a view whose parts arrive at
// different times (an editor's decorations after its widgets), so a play
// checks the state it means rather than whichever part came first.
function waitUntil(ready, what, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const poll = () => {
      let ok = false;
      try { ok = ready(); } catch { ok = false; }
      if (ok) return resolve();
      if (Date.now() - started > timeoutMs) return reject(new Error(`timed out waiting for ${what}`));
      setTimeout(poll, 25);
    };
    poll();
  });
}

// The computed font size of the first element matching `selector`, or null.
function fontSizeOf(root, selector) {
  const el = root.querySelector(selector);
  return el ? getComputedStyle(el).fontSize : null;
}

// The type size the desktop app draws its code, its panes' rows and the
// review's value chips at: measured in the running app at 1440x900 with the
// default configuration (2026-11-05), every one 16px, the window's own size.
// A story that mounted its panels inside `#main` (1.25rem) drew them at 20px.
const APP_TYPE_SIZE = "16px";

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

// The inbox's Previous / Next: the colour each arrow computes to, and the
// colours of the two roles it may take in the theme in view. The disabled
// role is read from a disabled `<button>` (CodeTracer's own `button:disabled`
// rule), the label role from a `.ah-inbox-position` inside the bar (the
// bar's rule draws the position in it). Transitions are held off while
// reading, so a value is the settled one, not a frame of a colour fade.
function settledColor(node) {
  const before = node.style.transition;
  node.style.transition = "none";
  try {
    return getComputedStyle(node).color;
  } finally {
    node.style.transition = before;
  }
}

function inboxRoleColors(el) {
  const group = el.querySelector(".ah-initiative-tab-bar .ah-inbox");
  const label = document.createElement("span");
  label.className = "ah-inbox-position";
  const disabled = document.createElement("button");
  disabled.disabled = true;
  group.appendChild(label);
  el.appendChild(disabled);
  try {
    return { label: settledColor(label), disabled: settledColor(disabled) };
  } finally {
    label.remove();
    disabled.remove();
  }
}

// Each arrow in the disabled role at full opacity while nothing waits (an
// empty inbox is the only state the wrapping steps are disabled in), in the
// label role otherwise; the two roles differ, so the arrows read differently.
function expectInboxStepInk(el) {
  const group = el.querySelector(".ah-initiative-tab-bar .ah-inbox");
  const steps = group.querySelectorAll(".ah-inbox-step");
  expect(steps.length).toBe(2);
  const roles = inboxRoleColors(el);
  expect(roles.disabled).not.toBe(roles.label);
  const wanted = group.classList.contains("ah-inbox-empty") ? roles.disabled : roles.label;
  for (const step of steps) {
    expect(settledColor(step)).toBe(wanted);
    expect(getComputedStyle(step).opacity).toBe("1");
  }
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
    // One fault is red once: under a red failure line the activity lines are
    // in the caption role, never the error colour, and none carries the
    // error class (`agent_harbor_words.activityLineIsError`).
    const withFailure = [...fleetRows(el)].filter(
      (r) => !r.classList.contains("ah-fleet-row-selected") && r.querySelector(".ah-fleet-row-failure"));
    expect(withFailure.length).toBeGreaterThan(0);
    const red = getComputedStyle(withFailure[0].querySelector(".ah-fleet-row-failure")).color;
    for (const row of withFailure) {
      for (const line of row.querySelectorAll(".ah-fleet-activity-line")) {
        expect(line.classList.contains("ah-fleet-activity-error")).toBe(false);
        expect(getComputedStyle(line).color).not.toBe(red);
      }
    }
    // The class the view sets on an error-level line of a row WITHOUT a
    // failure line (no such row is in the story data) does draw it red: the
    // rule is not overridden by the activity line's own colour rule.
    const probe = withFailure[0].querySelector(".ah-fleet-activity-line");
    probe.classList.add("ah-fleet-activity-error");
    try {
      expect(getComputedStyle(probe).color).toBe(red);
    } finally {
      probe.classList.remove("ah-fleet-activity-error");
    }
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
    // The active filter's 0 keeps the body role on its fill; another
    // filter's 0 is quieter (the disabled role).
    const active = el.querySelector(".ah-fleet-filter-active");
    const activeCount = active.querySelector(".ah-fleet-filter-count");
    expect(activeCount.textContent).toBe("0");
    expect(getComputedStyle(activeCount).color).toBe(getComputedStyle(active).color);
    const idle = el.querySelector(".ah-fleet-filter-empty:not(.ah-fleet-filter-active) .ah-fleet-filter-count");
    expect(getComputedStyle(idle).color).not.toBe(getComputedStyle(activeCount).color);
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
    // A count badge and its label, never bracketed; a compact bar keeps the
    // badge and puts the label in the tooltip.
    const item = el.querySelector(".ah-elsewhere");
    expect(item.querySelector(".ah-elsewhere-count")?.textContent).toMatch(/^\d+$/);
    expect(item.textContent).not.toMatch(/[\[\]]/);
    expect(item.getAttribute("title")).toMatch(/^\d+ agent harbor sessions? started elsewhere/);
    const rows = el.querySelectorAll(".ah-elsewhere-menu .session-tab-overflow-item");
    expect(rows.length).toBeGreaterThan(0);
    // Each session's initiative beside its state.
    for (const row of rows) {
      expect(row.querySelector(".ah-elsewhere-initiative")?.textContent.length).toBeGreaterThan(0);
      expect(row.querySelector(".ah-elsewhere-status")?.textContent.length).toBeGreaterThan(0);
    }
    // Drawn, not only in the DOM: the bar clips what overflows it unless a
    // menu is open.
    const menu = el.querySelector(".ah-elsewhere-menu");
    expect(menu.getBoundingClientRect().height).toBeGreaterThan(0);
    expect(getComputedStyle(el.querySelector(".ah-initiative-tab-bar")).overflow).toBe("visible");
  }),
  "agent-harbor-initiative-tabs-inbox": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-inbox");
    // The position is on the bar, or (compact bar) in the Next button's tooltip.
    const steps = el.querySelectorAll(".ah-inbox-step");
    const position = el.querySelector(".ah-inbox-position")?.textContent ?? steps[steps.length - 1]?.getAttribute("title");
    expect(position).toMatch(/of \d+|waiting|empty/);
    // Something waits here: the arrows are pressable, in the label role.
    expect(el.querySelector(".ah-inbox").classList.contains("ah-inbox-empty")).toBe(false);
    expectInboxStepInk(el);
    // The same arrows with nothing waiting take the disabled role: the
    // empty inbox's rule is not overridden by the bar's own colour rule.
    const group = el.querySelector(".ah-inbox");
    group.classList.add("ah-inbox-empty");
    try {
      expectInboxStepInk(el);
    } finally {
      group.classList.remove("ah-inbox-empty");
    }
  }),
  "agent-harbor-initiative-tabs-recordings": initiativeTabsCheck(async (el) => {
    await waitFor(el, ".ah-rec-button");
    // Twelve recordings: five buttons on a wide bar, the active one alone on
    // a compact one (the viewmodel's `RecordingSlots`), the rest behind `+N`.
    const compact = el.querySelector(".ah-initiative-tab-bar").classList.contains("ah-bar-compact");
    const shown = compact ? 1 : 5;
    expect(el.querySelectorAll(".ah-rec-button").length).toBe(shown);
    expect(el.querySelector(".ah-rec-more")?.textContent).toBe(`+${12 - shown}`);
    if (!compact) {
      // The states, where the buttons that carry them are drawn.
      expect(el.querySelector(".ah-rec-loading")).toBeTruthy();
      expect(el.querySelector(".ah-rec-failed")?.textContent).toMatch(/✕$/);
      expect(el.querySelector(".ah-rec-missing")?.textContent).toMatch(/\?$/);
    }
  }),
  "agent-harbor-initiative-tabs-empty": initiativeTabsCheck(async (el) => {
    expect(el.querySelector(".ah-tab-empty")?.textContent).toContain("No initiative");
    // Nothing waits: the arrows are drawn disabled, not pressable.
    await waitFor(el, ".ah-inbox.ah-inbox-empty");
    expectInboxStepInk(el);
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

  // A review with src/shield.nr selected: the changed-files list in the VCS
  // panel, and the file's diff tab with the values the recording holds
  // beside the changed lines, in the call the other stories are stopped
  // after (pass 2 of the positive field).
  //
  // Monaco draws the diff in parts: the value bands are content widgets and
  // the added-line wash is a decoration of a later render pass, so the play
  // waits for every part it checks, not only the first.
  "deep-review": async ({ canvasElement }) => {
    const chipTexts = () => [...canvasElement.querySelectorAll(".review-flow-band-host .ct-omni-value")]
      .map((chip) => chip.textContent.replace(/\s+/g, ""));
    await waitUntil(() =>
      canvasElement.querySelector(".unified-diff-file-header-host")?.textContent.includes("src/shield.nr") &&
      canvasElement.querySelectorAll(".view-overlays .ct-diff-line-added").length > 0 &&
      ["<damage>2000", "<remaining_shield>9000", "<shield_pct>90"].every((c) => chipTexts().includes(c)),
    "the diff's header, added-line decorations and value chips", 60000).catch(() => {});
    await expect(canvasElement.textContent).toContain("Clamp the shield at zero after a hit");
    await expect(canvasElement.querySelector(".unified-diff-file-header-host")?.textContent).toContain("src/shield.nr");
    await expect(canvasElement.querySelectorAll(".view-overlays .ct-diff-line-added").length).toBeGreaterThan(0);
    const chips = chipTexts();
    await expect(chips).toContain("<damage>2000");
    await expect(chips).toContain("<remaining_shield>9000");
    await expect(chips).toContain("<shield_pct>90");
    // The chips at the app's type size, the code's.
    const code = fontSizeOf(canvasElement, ".monaco-editor .view-line");
    await expect(code).toBe(APP_TYPE_SIZE);
    await expect(fontSizeOf(canvasElement, ".review-flow-band-host .ct-omni-value")).toBe(code);
  },

  // The editor's gutter is the app's (`editorGutterLineHtml`): the
  // execution-pointer arrow on the stopped line, and every line number clear
  // of the code.
  "editor-gutter": async ({ canvasElement }) => {
    await waitFor(canvasElement, ".monaco-editor .gutter-line", 60000);
    const arrow = canvasElement.querySelector(".gutter-highlight-active");
    await expect(arrow).toBeTruthy();
    await expect(arrow.closest(".gutter")?.dataset.line).toBe("7");
    const code = canvasElement.querySelector(".monaco-editor .view-lines").getBoundingClientRect();
    for (const number of canvasElement.querySelectorAll(".gutter-line")) {
      await expect(number.getBoundingClientRect().right).toBeLessThanOrEqual(code.left);
    }
  },

  // The debug shell as the app composes it: the caption bar's children in
  // the app's order with the omnibox between the toolbar and the session
  // tabs, the panels area and the status bar.
  "debug-shell": async ({ canvasElement }) => {
    await waitFor(canvasElement, "#debug input", 10000);
    const menu = canvasElement.querySelector("#menu");
    const order = [...menu.children].map((child) => child.id || child.className);
    const at = (id) => order.indexOf(id);
    await expect(at("isonim-debug-controls")).toBeGreaterThanOrEqual(0);
    await expect(at("debug")).toBe(at("isonim-debug-controls") + 1);
    await expect(at("session-tab-bar")).toBe(at("debug") + 1);
    const toolbar = menu.querySelector("#isonim-debug-controls").getBoundingClientRect();
    const omnibox = menu.querySelector("#debug").getBoundingClientRect();
    const tabs = menu.querySelector("#session-tab-bar").getBoundingClientRect();
    await expect(omnibox.left).toBeGreaterThanOrEqual(toolbar.right);
    await expect(omnibox.right).toBeLessThanOrEqual(tabs.left);
    await expect(menu.querySelectorAll("#isonim-debug-controls button").length).toBeGreaterThan(5);
    await expect(canvasElement.querySelectorAll("#ROOT .lm_stack").length).toBe(3);
    await expect(canvasElement.querySelector("#root-container footer #status")).toBeTruthy();
    // The panes at the app's type size, the code's.
    await waitFor(canvasElement, ".monaco-editor .view-line", 60000);
    const code = fontSizeOf(canvasElement, ".monaco-editor .view-line");
    await expect(code).toBe(APP_TYPE_SIZE);
    await expect(fontSizeOf(canvasElement, ".calltrace-call-line")).toBe(code);
    await expect(fontSizeOf(canvasElement, ".value-name")).toBe(code);
  },

  // The Shell pane's rows: each line's gutter mark sits beside its text, not
  // over it (a stylesheet rule left from the xterm pane once made the gutter
  // an absolute overlay that hid the first two columns of every line).
  "shell-rows": async ({ canvasElement }) => {
    await waitFor(canvasElement, ".isonim-shell .shell-row");
    // The header reads the session the rows come from: a running shell.
    await expect(canvasElement.querySelector(".isonim-shell .shell-status")?.textContent).toContain("running");
    const rows = [...canvasElement.querySelectorAll(".isonim-shell .shell-row")];
    await expect(rows.length).toBeGreaterThan(2);
    for (const row of rows) {
      const gutter = row.querySelector(".shell-gutter").getBoundingClientRect();
      const text = row.querySelector(".shell-text").getBoundingClientRect();
      await expect(text.left).toBeGreaterThanOrEqual(gutter.right - 0.5);
    }
    await expect(rows[0].querySelector(".shell-text").textContent).toContain("$ cd test-programs/noir_space_ship");
    // The command line the shell echoed comes before the program's output,
    // and the recording's range starts at that output, not at the command.
    const texts = rows.map((row) => row.querySelector(".shell-text").textContent.replace(/\s+$/, ""));
    const command = texts.indexOf("$ ct record .");
    const start = rows.findIndex((row) => row.getAttribute("data-mark") === "start");
    await expect(command).toBeGreaterThan(0);
    await expect(start).toBe(command + 1);
    await expect(texts[start]).toBe("Positive Test Case");
  },

  "frame-viewer": async ({ canvasElement }) => {
    const image = canvasElement.querySelector(".frame-viewer-image");
    await expect(image).toBeTruthy();
    // `toHaveAttribute` compares a value with `equals`, so a bare RegExp is
    // compared as an object and never matches a string; an asymmetric
    // matcher is how a value is matched against a pattern
    // (https://github.com/testing-library/jest-dom#tohaveattribute).
    await expect(image).toHaveAttribute("src", expect.stringMatching(/^data:image\/svg\+xml/));
    await expect(canvasElement.querySelector(".frame-viewer-draw-call")).toBeTruthy();

    const firstSrc = image.getAttribute("src");
    const label = canvasElement.querySelector(".frame-viewer-frame-label");
    const firstLabel = label.textContent;
    const next = canvasElement.querySelector(".frame-viewer-next-frame");
    next.click();
    await tick();
    await expect(image.getAttribute("src")).not.toBe(firstSrc);
    await expect(label.textContent).not.toBe(firstLabel);

    // Step back, so the story is left on the frame it opened on: a reader
    // of the story, and the Playwright suite that drives the same story
    // after this play has run (frame-viewer-storybook.spec.ts), start from
    // the first frame. Returning also checks the previous-frame control.
    canvasElement.querySelector(".frame-viewer-prev-frame").click();
    await tick();
    await expect(image.getAttribute("src")).toBe(firstSrc);
    await expect(label.textContent).toBe(firstLabel);
  },
};
