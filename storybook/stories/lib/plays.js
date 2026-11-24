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

// What every story of the initiative bar with tabs must draw: the tabs, each
// with its progress pie (one, named by its words) and its state class, its
// `n/m` in its tooltip rather than on the tab, and exactly one active.
async function initiativeTabsDrawn(el) {
  await waitFor(el, ".ah-initiative-tab");
  expect(el.querySelectorAll(".ah-initiative-tab").length).toBeGreaterThan(0);
  for (const tab of el.querySelectorAll(".ah-initiative-tab")) {
    const pies = tab.querySelectorAll(":scope > .ah-tab-pie > .ah-pie");
    expect(pies.length).toBe(1);
    expect(pies[0].getAttribute("role")).toBe("img");
    expect(pies[0].getAttribute("aria-label")).toMatch(/\S/);
    expect(tab.querySelector(".ah-tab-progress")).toBeNull();
    expect(tab.getAttribute("title")).toMatch(/\d+\/\d+ milestones/);
    expect([...tab.classList].some((c) => c.startsWith("ah-ist-"))).toBe(true);
  }
  expect(el.querySelectorAll(".ah-initiative-tab.active").length).toBe(1);
}

// A strip's +N menu hangs from its chip: its right edge on the chip's right
// edge, shifted only as far as it must be to stay inside the window on either
// side. `bar` names the strip: the session strip or the initiative bar.
async function overflowMenuHangs(el, bar) {
  await waitFor(el, `${bar} > .session-tab-overflow-menu .session-tab-overflow-item`);
  // A face arriving late moves the chip; the view places the menu again.
  await document.fonts.ready;
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
  const chip = el.querySelector(`${bar} > .ah-tab-overflow-count`).getBoundingClientRect();
  const menu = el.querySelector(`${bar} > .session-tab-overflow-menu`).getBoundingClientRect();
  const view = document.documentElement.clientWidth;
  expect(menu.height).toBeGreaterThan(0);
  const left = Math.max(0, Math.min(chip.right - menu.width, view - menu.width));
  // To half a pixel: the browser places the menu in fractions of one.
  expect(menu.left).toBeCloseTo(left, 0);
  expect(menu.left).toBeGreaterThanOrEqual(-0.5);
  expect(menu.right).toBeLessThanOrEqual(view + 0.5);
  if (left === chip.right - menu.width) expect(menu.right).toBeCloseTo(chip.right, 0);
}

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

// --- The omnibox composer (CTF-P2c) --------------------------------------
// Each composer story is one moment of the composer over the CTF-P2L
// project (`stories/agent_harbor_composer_stories.nim`). The checks read what
// the sheet draws: its phase and routing state, the header, each
// destination row's mark, delivery and actions, the chips and the form.

// Where every composer story's sheet hangs (note 237, the coordinator's
// follow-up): DROPDOWN_TRIGGER_GAP (6px) below the field, and its tallest
// form still 1rem (16px) above the window's foot, so the gap does not eat
// into that clearance.
function expectSheetPlaced(el) {
  const sheet = el.querySelector(".ah-composer-sheet");
  if (!sheet || !sheet.offsetParent) return;
  const s = sheet.getBoundingClientRect();
  if (s.height === 0) return;
  // The block the sheet hangs from (`top: calc(100% + gap)`): the field's row.
  const f = sheet.offsetParent.getBoundingClientRect();
  expect(Math.round(s.top - f.bottom)).toBe(6);
  expect(s.bottom).toBeLessThanOrEqual(window.innerHeight - 16 + 0.5);
}
const composerCheck = (assert) => hostCheck(".ah-composer-sheet", async (el) => {
  await assert(el);
  expectSheetPlaced(el);
});
const sheetOf = (el) => el.querySelector(".ah-composer-body");
const headerOf = (el) => el.querySelector(".ah-composer-header")?.textContent ?? "";
const rowOf = (el, target) => el.querySelector(`.ah-composer-row[data-ah-target="${target}"]`);
const rowMark = (el, target) => rowOf(el, target)?.querySelector(".ah-composer-row-mark")?.textContent ?? "";
const rowDelivery = (el, target) => rowOf(el, target)?.querySelector(".ah-composer-row-delivery")?.textContent ?? "";
// After sending, the state word (the mark's slot) says the delivery's state.
const selectedTargets = (el) => [...el.querySelectorAll(".ah-composer-row-selected")].map((r) => r.dataset.ahTarget);
const chipStates = (el) => Object.fromEntries([...el.querySelectorAll(".ah-composer-chip[data-ah-target]")]
  .map((c) => [c.dataset.ahTarget, c.dataset.ahChip]));
const sendButton = (el) => el.querySelector(".ah-composer-send-button");
const destinationsInOrder = (el) =>
  expect([...el.querySelectorAll(".ah-composer-row")].map((r) => r.dataset.ahTarget))
    .toEqual(["session", "manager", "ui-action"]);

// WCAG 2's contrast ratio of two computed colours
// (https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio): how far an ink stands
// off the ground it is drawn on.
function contrastOf(a, b) {
  const lum = (css) => {
    const [r, g, bl] = css.match(/[\d.]+/g).slice(0, 3).map((v) => {
      const c = Number(v) / 255;
      return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [la, lb] = [lum(a), lum(b)];
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// A context item the operator left out reads dimmer than an offered one, in
// both themes (manager note 122): its ink's contrast on the sheet at most
// four fifths of an offered chip's. In Light the disabled role it had
// (4.46:1) was no dimmer than the offered chips' caption (4.25:1); the
// caption-subtle role is 2.90:1.
function expectLeftOutChipDimmer(el) {
  const ground = getComputedStyle(el.querySelector(".ah-composer-sheet")).backgroundColor;
  expect(TRANSPARENT.has(ground)).toBe(false);
  const inkOf = (state) => {
    const chip = el.querySelector(`.ah-composer-chip[data-ah-chip="${state}"] .ah-composer-chip-text`);
    expect(chip).toBeTruthy();
    return settledColor(chip);
  };
  const left = contrastOf(inkOf("uncited"), ground);
  const offered = contrastOf(inkOf("offered"), ground);
  expect(left).toBeLessThanOrEqual(offered * 0.8);
}

// The width the sheet has in the brief's sidebar window (360px):
// `min(40rem, 100vw - 1rem)`.
const SIDEBAR_SHEET_PX = 344;

// A form field's value wider than its field is cut in its MIDDLE (the P2c
// study's D35, manager note 128), as GPUI and the terminal cut it: what is
// drawn (`data-ah-shown`) is the value's start, one "…", and the value's
// end, each side non-empty; the element keeps the whole value, and its
// tooltip says it. The sheet is held at its sidebar width while this
// reads, so the check cuts at the size the note is about whatever window
// the story runs in, then given back its own width.
async function expectMiddleCutAtSidebar(el, fields) {
  const sheet = el.querySelector(".ah-composer-sheet");
  const own = sheet.style.width;
  sheet.style.width = `${SIDEBAR_SHEET_PX}px`;
  const values = fields.map((name) => el.querySelector(`[data-ah-field="${name}"] .ah-composer-field-value`));
  try {
    for (const [i, value] of values.entries()) {
      expect(value).toBeTruthy();
      const whole = value.textContent;
      await waitUntil(() => value.hasAttribute("data-ah-shown"), `${fields[i]} cut at the sidebar's width`);
      const shown = value.getAttribute("data-ah-shown");
      const parts = shown.split("…");
      expect(parts.length).toBe(2);
      const [head, tail] = parts;
      expect(head.length).toBeGreaterThan(0);
      expect(tail.length).toBeGreaterThan(0);
      expect(whole.startsWith(head)).toBe(true);
      expect(whole.endsWith(tail)).toBe(true);
      expect(globalThis.ahCutTextDangles(shown)).toBe(false);
      expect(value.getAttribute("title")).toBe(whole);
    }
  } finally {
    sheet.style.width = own;
  }
  // Back at its own width, each field is drawn as it was before the check.
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
}

async function composedTo(el, target, mark = "Routed") {
  expect(sheetOf(el).dataset.ahPhase).toBe("composing");
  destinationsInOrder(el);
  expect(selectedTargets(el)).toEqual([target]);
  expect(rowMark(el, target)).toBe(mark);
}

const composerChecks = {
  "agent-harbor-composer-recent": composerCheck(async (el) => {
    expect(headerOf(el)).toContain("Type an instruction.");
    expect(el.querySelectorAll(".ah-composer-recent-row").length).toBe(5);
    expect(el.querySelector(".ah-composer-row")).toBeNull();
    expect(el.querySelector(".ah-composer-input").value).toBe("/ai ");
  }),
  "agent-harbor-composer-typing": composerCheck(async (el) => {
    await composedTo(el, "session");
    expect(el.querySelector(".ah-composer-input").value).toBe("/ai Also test a hit on an empty shield");
    expect(chipStates(el)).toMatchObject({ file: "cited", replay: "cited", selection: "offered", pane: "offered" });
    expect(el.querySelector(".ah-composer-cites").textContent).toBe("Cites src/shield.nr:7, Pass 2 of iterate_asteroids");
    expect(sendButton(el).textContent).toBe("Send");
    expect(sendButton(el).disabled).toBe(false);
  }),
  "agent-harbor-composer-multi-line": composerCheck(async (el) => {
    expect(el.querySelector(".ah-composer-more-text")?.textContent).toBe("+2 lines");
    expect(el.querySelector(".ah-composer-instruction")?.textContent).toContain("The status report must still say");
  }),
  "agent-harbor-composer-routing": composerCheck(async (el) => {
    expect(sheetOf(el).dataset.ahRoute).toBe("routing");
    expect(headerOf(el)).toBe("Routing… · Enter sends it when routed");
    expect([...el.querySelectorAll(".ah-composer-row-mark")].map((m) => m.textContent))
      .toEqual(["", "", ""]);
    expect(selectedTargets(el)).toEqual([]);
  }),
  "agent-harbor-composer-sends-when-routed": composerCheck(async (el) => {
    expect(sheetOf(el).dataset.ahPhase).toBe("sending");
    expect(headerOf(el)).toBe("Routing… · sends when routed");
    expect(el.querySelector(".ah-composer-row-delivery")).toBeNull();
    expect(el.querySelector(".ah-composer-send-hint").textContent).toBe("Sends when routed");
    expect(sendButton(el).disabled).toBe(true);
  }),
  "agent-harbor-composer-manager": composerCheck(async (el) => {
    await composedTo(el, "manager");
    expect(el.querySelector(".ah-composer-cites").textContent).toBe("Cites nothing from this window");
  }),
  "agent-harbor-composer-ui-action": composerCheck(async (el) => {
    await composedTo(el, "ui-action");
    expect(rowOf(el, "ui-action").querySelector(".ah-composer-row-label").textContent)
      .toContain("Open calculate_damage");
  }),
  "agent-harbor-composer-redirected": composerCheck(async (el) => {
    await composedTo(el, "session", "Chosen by you");
    expect(rowMark(el, "manager")).toBe("Router's choice");
    expect(headerOf(el)).toBe("Enter sends it where you chose");
  }),
  "agent-harbor-composer-no-session": composerCheck(async (el) => {
    await composedTo(el, "manager");
    expect(rowOf(el, "session").classList.contains("ah-composer-row-unavailable")).toBe(true);
    expect(rowOf(el, "session").textContent).toContain("No agent session in this window");
    // No session of its own: the reason stands in the label's place.
    expect(rowOf(el, "session").querySelector(".ah-composer-row-label").textContent)
      .toBe("No agent session in this window");
    expect(rowOf(el, "session").querySelector(".ah-composer-row-reason")).toBeNull();
    expect(el.querySelector(".ah-composer-none")?.textContent).toBe("nothing");
  }),
  "agent-harbor-composer-context-edited": composerCheck(async (el) => {
    expect(chipStates(el)).toMatchObject({ file: "cited", replay: "uncited", pane: "cited" });
    expectLeftOutChipDimmer(el);
  }),
  "agent-harbor-composer-add-context": composerCheck(async (el) => {
    expect([...el.querySelectorAll(".ah-composer-menu-item")].map((i) => i.textContent))
      .toEqual(["Upload attachment", "Files & folders", "Editor selection", "Recording / trace"]);
  }),
  "agent-harbor-composer-sending": composerCheck(async (el) => {
    expect(sheetOf(el).dataset.ahPhase).toBe("sending");
    expect(rowMark(el, "session")).toBe("Sending…");
    expect(rowDelivery(el, "session")).toBe("");
    expect(sendButton(el).disabled).toBe(true);
  }),
  "agent-harbor-composer-sent": composerCheck(async (el) => {
    expect(sheetOf(el).dataset.ahPhase).toBe("sent");
    expect(rowMark(el, "session")).toBe("Sent");
    expect(el.querySelector(".ah-composer-sent-line").textContent).toBe("Sent to this session");
    expect([...el.querySelectorAll('[data-ah-action="send-again"]')].map((b) => b.dataset.ahTarget))
      .toEqual(["manager", "ui-action"]);
  }),
  "agent-harbor-composer-sent-again": composerCheck(async (el) => {
    expect(el.querySelector(".ah-composer-sent-line").textContent)
      .toBe("Sent to this session · redirected to the manager agent");
    // The bar marks the newest delivery only; each delivered row says Sent.
    expect(selectedTargets(el)).toEqual(["manager"]);
    expect(rowMark(el, "session")).toBe("Sent");
    expect(rowMark(el, "manager")).toBe("Sent");
  }),
  "agent-harbor-composer-send-failed": composerCheck(async (el) => {
    expect(sheetOf(el).dataset.ahPhase).toBe("send-failed");
    expect(rowMark(el, "manager")).toBe("Failed to send");
    expect(rowDelivery(el, "manager")).toBe("Agent Harbor answered 503 (the hub is restarting)");
    expect(rowOf(el, "manager").querySelector('[data-ah-action="retry"]')).toBeTruthy();
    // Said by the header and the row only (P2c D37): the instruction as
    // sent, and no line naming where it went.
    expect(headerOf(el)).toBe("Failed to send");
    expect(el.querySelector(".ah-composer-sent-text")?.textContent).toContain("Which milestone");
    expect(el.querySelector(".ah-composer-sent-line")).toBeNull();
  }),
  "agent-harbor-composer-route-failed": composerCheck(async (el) => {
    expect(headerOf(el)).toBe("Could not route: the routing agent did not answer within 20 s");
    expect(selectedTargets(el)).toEqual(["session"]);
    expect(rowOf(el, "session").querySelector(".ah-composer-row-reason").textContent)
      .toBe("Shown because the router did not answer");
    expect(sendButton(el).disabled).toBe(false);
  }),
  "agent-harbor-composer-stop": composerCheck(async (el) => {
    expect(rowOf(el, "session").querySelector('[data-ah-action="stop"]')?.textContent).toBe("Stop agent");
  }),
  "agent-harbor-composer-ui-done": composerCheck(async (el) => {
    expect(rowDelivery(el, "ui-action")).toBe("Opened calculate_damage (src/shield.nr:22) beside src/shield.nr");
  }),
  "agent-harbor-composer-ui-refused": composerCheck(async (el) => {
    expect(rowDelivery(el, "ui-action")).toMatch(/^Refused: /);
    expect(rowOf(el, "ui-action").querySelector(".ah-role-warning")).toBeTruthy();
  }),
  "agent-harbor-composer-ui-partial": composerCheck(async (el) => {
    expect(rowDelivery(el, "ui-action")).toMatch(/^Done 1 of 2: /);
    expect(rowOf(el, "ui-action").querySelector(".ah-role-warning")).toBeTruthy();
  }),
  "agent-harbor-composer-launch": composerCheck(async (el) => {
    await composedTo(el, "manager");
    expect(el.querySelector(".ah-composer-form").dataset.ahForm).toBe("launch-task");
    expect(sendButton(el).textContent).toBe("Launch");
    expect(sendButton(el).disabled).toBe(false);
  }),
  "agent-harbor-composer-launch-invalid": composerCheck(async (el) => {
    expect(sendButton(el).disabled).toBe(true);
    expect(el.querySelector(".ah-composer-send-hint").textContent).toBe("Choose a repository");
    expect(el.querySelector(".ah-composer-send-more").textContent).toBe(" · 3 more");
    expect(headerOf(el)).toBe("Complete the form to send · 4 problems · to Manager of Shield model hardening");
    const problems = [...el.querySelectorAll(".ah-composer-field-problem-text")].map((p) => p.textContent);
    expect(problems).toEqual(["Choose a repository", "Choose at least one agent", "Choose an executor"]);
    // The folded schedule says its own problem on its head line.
    expect(el.querySelector(".ah-composer-schedule-problem").textContent)
      .toBe("The hour field allows 0-23; 25 is out of range");
  }),
  "agent-harbor-composer-launch-scheduled": composerCheck(async (el) => {
    expect(el.querySelector(".ah-composer-schedule-open")).toBeTruthy();
    // Opening the schedule brought it into view in the scrolling body.
    const body = el.querySelector(".ah-composer-body");
    // Its end -- the last field, Misfire -- is wholly inside the body's view.
    const misfire = el.querySelector('[data-ah-field="Misfire"]');
    await waitUntil(() => misfire.getBoundingClientRect().bottom <=
                          body.getBoundingClientRect().bottom + 1 &&
                          misfire.getBoundingClientRect().top >= body.getBoundingClientRect().top,
                    "the open schedule's end scrolled into view");
    // The schedule is the form's last part: scrolled to it, nothing is
    // below, so no "More below" line claims there is.
    await waitUntil(() => !body.hasAttribute("data-ah-more"), "no More below at the end");
    expect(el.querySelector('[data-ah-field="Cron"] .ah-composer-field-value').textContent).toBe("30 6 * * 1-5");
  }),
  "agent-harbor-composer-launched": composerCheck(async (el) => {
    expect(rowMark(el, "manager")).toBe("Sent");
    expect(rowDelivery(el, "manager")).toBe("Started on hub-a · executor linux-x64-4 · session 5c1a3e70");
  }),
  "agent-harbor-composer-new-initiative": composerCheck(async (el) => {
    expect(sendButton(el).textContent).toBe("Start initiative");
    expect(el.querySelector('[data-ah-field="Plan file"] .ah-composer-field-value').textContent)
      .toBe("milestones/2026-11-17-asteroid-fields-generated-from-seeds-end.milestones.org");
    await expectMiddleCutAtSidebar(el, ["Goal", "Plan file"]);
  }),
  "agent-harbor-composer-new-initiative-invalid": composerCheck(async (el) => {
    expect(sendButton(el).disabled).toBe(true);
    expect([...el.querySelectorAll(".ah-composer-field-problem-text")].map((p) => p.textContent))
      .toEqual(["The number of iterations is at least 1", "The plan file is a path inside the workspace"]);
    expect(el.querySelector('[data-ah-field="Number of iterations"] .ah-composer-field-value').textContent).toBe("0");
  }),
  "agent-harbor-composer-gaze": composerCheck(async (el) => {
    expect(chipStates(el).gaze).toBe("cited");
    expect(el.querySelector('.ah-composer-chip[data-ah-target="gaze"]').textContent)
      .toBe("Looked at remaining_shield -= damage · 1.4 s");
  }),
  "agent-harbor-composer-gaze-paused": composerCheck(async (el) => {
    expect(chipStates(el)["gaze-paused"]).toBe("note");
  }),
  // Tracking, the gaze on nothing the window can attach: a quiet note, never
  // cited (P2c study D67).
  "agent-harbor-composer-gaze-nothing": composerCheck(async (el) => {
    expect(chipStates(el)["gaze-nothing"]).toBe("note");
    expect(el.querySelector('.ah-composer-chip[data-ah-target="gaze-nothing"]').textContent)
      .toBe("Looked at nothing in view");
    expect(el.querySelector(".ah-composer-cites")?.textContent ?? "").not.toContain("nothing");
  }),
  "agent-harbor-composer-long-names": composerCheck(async (el) => {
    await composedTo(el, "session");
    expect(el.querySelectorAll(".ah-chip-cited").length).toBe(4);
  }),
};


// --- The session activity timeline (CTF-P2b) -------------------------------
//
// The timeline is cardless: no border, outline, shadow or background around
// an event. `cardlessProblems` reads every drawn line (`[data-ah-line]`) and
// every element inside it from the browser's computed styles: each border
// side 0 (or `none`), no outline, a background that is transparent or the
// panel's own ground, and no shadow -- except the focused line's one inset
// bar (`.ah-activity-focused`, `box-shadow: inset`), which is a bar, not a
// fill.
const TRANSPARENT = new Set(["rgba(0, 0, 0, 0)", "transparent"]);
function cardlessProblems(panel) {
  const ground = getComputedStyle(panel).backgroundColor;
  const problems = [];
  for (const line of panel.querySelectorAll("[data-ah-line]")) {
    const id = line.getAttribute("data-ah-line");
    for (const e of [line, ...line.querySelectorAll("*")]) {
      const cs = getComputedStyle(e);
      for (const side of ["Top", "Right", "Bottom", "Left"]) {
        if (parseFloat(cs[`border${side}Width`]) > 0 && cs[`border${side}Style`] !== "none") {
          problems.push(`${id}: a ${side.toLowerCase()} border on ${e.className}`);
        }
      }
      if (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0) {
        problems.push(`${id}: an outline on ${e.className}`);
      }
      if (!TRANSPARENT.has(cs.backgroundColor) && cs.backgroundColor !== ground) {
        problems.push(`${id}: the background ${cs.backgroundColor} on ${e.className}`);
      }
      if (cs.boxShadow !== "none") {
        // The focus bar: one inset shadow on the focused line itself.
        const bar = e === line && line.classList.contains("ah-activity-focused") &&
          /inset/.test(cs.boxShadow) && !/\),|px,/.test(cs.boxShadow.replace(/rgba?\([^)]*\)/g, "c"));
        if (!bar) problems.push(`${id}: the shadow ${cs.boxShadow} on ${e.className}`);
      }
    }
  }
  return problems;
}

// The check can fail: a copy of a drawn line given a 1px border is reported,
// and a copy given the focus bar is not. Both copies are removed at once, so
// the story is left as it stood.
function cardlessControl(panel) {
  const line = panel.querySelector("[data-ah-line]");
  const host = line.parentElement;
  const planted = line.cloneNode(true);
  planted.setAttribute("data-ah-line", "planted-border");
  planted.classList.remove("ah-activity-focused");
  planted.style.border = "1px solid red";
  const focused = line.cloneNode(true);
  focused.setAttribute("data-ah-line", "planted-focus");
  focused.classList.add("ah-activity-focused");
  host.append(planted, focused);
  try {
    const found = cardlessProblems(panel);
    expect(found.some((p) => p.startsWith("planted-border:"))).toBe(true);
    expect(found.filter((p) => p.startsWith("planted-focus:"))).toEqual([]);
  } finally {
    planted.remove();
    focused.remove();
  }
}

const lineState = (panel) => [...panel.querySelectorAll("[data-ah-line]")].map((l) =>
  [l.getAttribute("data-ah-line"), l.getAttribute("data-ah-expanded") ?? "", l.getAttribute("data-ah-focused") ?? ""].join("|"));
const lineById = (panel, id) => [...panel.querySelectorAll("[data-ah-line]")].find((l) => l.getAttribute("data-ah-line") === id);
const toggleOf = (line) => line?.querySelector(":scope > .ah-activity-toggle");

// The timeline's own checks, over any of its stories: the head, then for a
// drawn timeline the cardless rule (with its control), a running command
// named on its group line, every Copy routed with its text, and every line
// tagged as the hosts' tests read it.
async function activityChecks(canvasElement) {
  const panel = await waitFor(canvasElement, ".agent-harbor-activity[data-ah-state]");
  expect(panel.getAttribute("data-ct-pane")).toBe("sessionActivity");
  expect(panel.querySelector(".ah-activity-status")?.textContent.length).toBeGreaterThan(0);
  const state = panel.getAttribute("data-ah-state");
  if (state !== "ready") {
    if (state === "error") {
      const retry = panel.querySelector(".ah-activity-retry");
      if (retry) {
        expect(retry.getAttribute("data-ct-operation")).toBe("session-activity.retry");
        retry.click();
        await waitUntil(() => panel.getAttribute("data-ah-state") === "error" &&
          panel.querySelector(".ah-activity-retry"), "the error again after Retry");
      }
    }
    return panel;
  }
  const lines = panel.querySelectorAll("[data-ah-line]");
  if (panel.querySelector("[data-ah-notice]")) return panel;
  expect(lines.length).toBeGreaterThan(0);
  expect(cardlessProblems(panel)).toEqual([]);
  cardlessControl(panel);
  // A running command is never hidden: a group that holds one names it.
  for (const group of panel.querySelectorAll('[data-ah-line-kind="group"]')) {
    if (Number(group.getAttribute("data-ah-running")) > 0) {
      expect(group.querySelector(".ah-activity-role-running")?.textContent.length).toBeGreaterThan(0);
      expect(group.querySelector(".ah-activity-running-mark")).toBeTruthy();
    }
  }
  // A line that opens carries its press, on itself.
  for (const line of panel.querySelectorAll('[data-ah-expanded]')) {
    const t = toggleOf(line);
    expect(t?.getAttribute("data-ct-operation")).toBe("session-activity.toggle");
    expect(t?.getAttribute("data-ah-target")).toBe(line.getAttribute("data-ah-line"));
  }
  // Copy hands its text to the host's clipboard, through the router.
  const copy = panel.querySelector(".ah-activity-copy");
  if (copy) {
    expect(copy.getAttribute("data-ct-operation")).toBe("session-activity.copy");
    document.body.removeAttribute("data-ah-copied");
    copy.click();
    await waitUntil(() => document.body.getAttribute("data-ah-copied") === copy.getAttribute("data-ah-target"),
      "the copied text on the host's clipboard");
  }
  const chip = panel.querySelector(".ah-activity-unseen");
  if (chip) {
    expect(chip.getAttribute("data-ct-operation")).toBe("session-activity.jump-to-latest");
    expect(chip.textContent).toBe(`${chip.getAttribute("data-ah-unseen")} new · Jump to latest`);
  }
  return panel;
}

// The focused story also drives the timeline as a reader does, then leaves
// it as it stood: a press on a group opens it, on one of its items opens
// that, on a command's trace opens the trace (levels 1 to 3), and the same
// presses close them; then the keys: Down and Up move the focus, Right and
// Left open and close the focused line, Enter steps in and Left steps out,
// `+` opens every group and `-` closes everything.
async function activityReader(panel) {
  const before = lineState(panel);
  const focusedId = panel.querySelector('[data-ah-focused="true"]')?.getAttribute("data-ah-line");
  expect(focusedId).toBeTruthy();
  const press = async (line, expanded) => {
    const id = line.getAttribute("data-ah-line");
    toggleOf(line).click();
    await waitUntil(() => lineById(panel, id)?.getAttribute("data-ah-expanded") === String(expanded),
      `${id} ${expanded ? "open" : "closed"}`);
    return lineById(panel, id);
  };
  const group = panel.querySelector('[data-ah-line-kind="group"][data-ah-item-kind="shell"][data-ah-expanded="false"]');
  expect(group).toBeTruthy();
  const opened = [await press(group, true)];
  const childOf = (parent, kind) => {
    const all = [...panel.querySelectorAll("[data-ah-line]")];
    const at = all.indexOf(lineById(panel, parent.getAttribute("data-ah-line")));
    for (const l of all.slice(at + 1)) {
      if (Number(l.getAttribute("data-ah-indent")) <= Number(parent.getAttribute("data-ah-indent"))) break;
      if (l.getAttribute("data-ah-expanded") === "false" && (!kind || l.getAttribute("data-ah-line-kind") === kind)) return l;
    }
    return null;
  };
  const item = childOf(opened[0], "item");
  expect(item).toBeTruthy();
  opened.push(await press(item, true));
  const trace = childOf(opened[1], "trace");
  if (trace) opened.push(await press(trace, true));
  for (const line of opened.reverse()) await press(lineById(panel, line.getAttribute("data-ah-line")), false);
  // The keys, from the group line the presses left focused back to the
  // story's own focused line.
  const list = panel.querySelector(".ah-activity-lines");
  const key = async (k) => {
    panel.querySelector(".ah-activity-lines").dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
    await tick();
  };
  const focused = () => panel.querySelector('[data-ah-focused="true"]')?.getAttribute("data-ah-line");
  expect(list).toBeTruthy();
  const order = [...panel.querySelectorAll("[data-ah-line]")].map((l) => l.getAttribute("data-ah-line"));
  for (let guard = 0; focused() !== focusedId && guard < order.length; guard++) {
    await key(order.indexOf(focused()) > order.indexOf(focusedId) ? "ArrowUp" : "ArrowDown");
  }
  expect(focused()).toBe(focusedId);
  await key("ArrowDown");
  await waitUntil(() => focused() !== focusedId, "Down moves the focus");
  await key("ArrowUp");
  await waitUntil(() => focused() === focusedId, "Up moves it back");
  await key("ArrowRight");
  await waitUntil(() => lineById(panel, focusedId)?.getAttribute("data-ah-expanded") === "true", "Right opens the focused line");
  await key("ArrowLeft");
  await waitUntil(() => lineById(panel, focusedId)?.getAttribute("data-ah-expanded") === "false", "Left closes it");
  await key("Enter");
  await waitUntil(() => focused() !== focusedId && lineById(panel, focusedId)?.getAttribute("data-ah-expanded") === "true",
    "Enter opens it and steps in");
  await key("ArrowLeft");
  await waitUntil(() => focused() === focusedId && lineById(panel, focusedId)?.getAttribute("data-ah-expanded") === "false",
    "Left steps out and closes it");
  await key("+");
  await waitUntil(() => [...panel.querySelectorAll('[data-ah-line-kind="group"]')].every((g) => g.getAttribute("data-ah-expanded") === "true"),
    "+ opens every group");
  await key("-");
  await waitUntil(() => panel.querySelectorAll('[data-ah-expanded="true"]').length === 0, "- closes everything");
  expect(lineState(panel)).toEqual(before);
}

// --- The omnibox's result commands (CTF-P2c step 2) ---------------------
// Each story is one moment of `/s`, `/ah…` or an instruction's sigil
// completion over the CTF-P2L project
// (`stories/agent_harbor_results_stories.nim`). The checks read what the
// sheet draws: the field, the header, each group's id, state and rows, the
// line in place of the rows, a row's tag, its box and what opening it said.

const resultsCheck = (assert) => hostCheck(".ah-results-sheet", assert);
const resultsHeader = (el) => el.querySelector(".ah-results .ah-composer-header")?.textContent ?? "";
const resultsField = (el) => el.querySelector(".ah-results .ah-composer-input")?.value ?? "";
const groupsOf = (el) => [...el.querySelectorAll(".ah-results-group")].map((g) => ({
  id: g.dataset.ahGroup, state: g.dataset.ahState,
  word: g.querySelector(".ah-results-state")?.textContent ?? "",
  rows: [...g.querySelectorAll(".ah-results-row")].map((r) => r.querySelector(".ah-results-title").dataset.ahTitle),
  more: g.querySelector(".ah-results-more")?.textContent ?? "",
}));
const groupById = (el, id) => groupsOf(el).find((g) => g.id === id);
const resultsNotice = (el) => el.querySelector(".ah-results-notice-text")?.textContent ?? "";
const searchGroups = ["files", "symbols", "program-text", "agent-harbor-search"];
// The providers that answered with nothing: one quiet line after the groups
// (P2c D60), no group of their own.
const emptyProviders = (el) => el.querySelector(".ah-results-empty")?.textContent ?? "";
function expectEmptyLineLast(el) {
  const line = el.querySelector(".ah-results-empty");
  expect(line).toBeTruthy();
  // After every group, in the caption role, not the error role.
  const groups = [...el.querySelectorAll(".ah-results-group")];
  if (groups.length > 0) {
    expect(groups[groups.length - 1].compareDocumentPosition(line) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  }
  expect(line.classList.contains("ah-role-error")).toBe(false);
}
// A line of the program's text is one line, cut around its match, which
// stays whole (P2c D62): its drawn text (the cut, or the whole line when it
// fits) holds the query, at most one "…" on each side, on one line box.
function expectMatchedLinesWhole(el, query) {
  const codes = [...el.querySelectorAll(".ah-results-title-code")];
  expect(codes.length).toBeGreaterThan(0);
  for (const c of codes) {
    expect(c.getAttribute("data-ah-cut")).toBe("match");
    expect(c.getAttribute("title")).toBe(c.dataset.ahTitle);
    const drawn = c.getAttribute("data-ah-shown") ?? c.dataset.ahTitle;
    expect(drawn.toLowerCase()).toContain(query);
    // The match stays bold, cut or not.
    const bold = c.hasAttribute("data-ah-shown") ?
      c.querySelector(":scope > .ah-cut-overlay b")?.textContent :
      c.querySelector(".ah-results-match")?.textContent;
    expect((bold ?? "").toLowerCase()).toBe(query);
    expect((drawn.match(/…/g) ?? []).length).toBeLessThanOrEqual(2);
    const lineHeight = parseFloat(getComputedStyle(c).lineHeight) || 20;
    expect(c.getBoundingClientRect().height).toBeLessThan(lineHeight * 1.5);
  }
}

const resultsChecks = {
  "agent-harbor-results-search-partial": resultsCheck(async (el) => {
    expect(resultsField(el)).toBe("/s shield");
    expect(groupsOf(el).map((g) => g.id)).toEqual(searchGroups);
    expect(groupById(el, "program-text").word).toBe("searching…");
    expect(groupById(el, "program-text").rows).toEqual([]);
    expect(groupById(el, "files").rows).toEqual(["src/shield.nr"]);
    expect(resultsHeader(el)).toBe("Searching… 3 of 4 providers answered");
  }),
  "agent-harbor-results-search-final": resultsCheck(async (el) => {
    expect(groupsOf(el).map((g) => g.state)).toEqual(["answered", "answered", "answered", "answered"]);
    expect(groupById(el, "program-text").word).toBe("42");
    expect(groupById(el, "program-text").rows.length).toBe(8);
    expect(groupById(el, "program-text").more).toBe("+34 more");
    expect(resultsHeader(el)).toBe("60 results from 4 providers · Enter opens");
    expectMatchedLinesWhole(el, "shield");
    // The query's match is drawn in bold, in the title's own role.
    expect(el.querySelector(".ah-results-row .ah-results-match")?.textContent.toLowerCase()).toBe("shield");
    expect(el.querySelectorAll(".ah-results-row-selected").length).toBe(1);
  }),
  "agent-harbor-results-search-failed": resultsCheck(async (el) => {
    const harbor = groupById(el, "agent-harbor-search");
    expect(harbor.state).toBe("failed");
    expect(harbor.word).toBe("failed: Agent Harbor is not reachable");
    expect(el.querySelector('.ah-results-group[data-ah-group="agent-harbor-search"] .ah-results-state-error')).toBeTruthy();
    // Named in the header too, whatever the body scrolled past, but the
    // summary stays neutral: only the failed group is in the error role (D61).
    expect(resultsHeader(el)).toBe("3 results from 3 of 4 providers · Agent Harbor sessions failed · Enter opens");
    expect(el.querySelector(".ah-results .ah-composer-header.ah-role-error")).toBeNull();
    expect(groupById(el, "symbols").rows).toEqual(["calculate_damage"]);
    // Files answered with nothing: named on the quiet line, not a group.
    expect(groupById(el, "files")).toBeUndefined();
    expect(emptyProviders(el)).toBe("No matches in Files");
    expectEmptyLineLast(el);
  }),
  "agent-harbor-results-search-no-symbols": resultsCheck(async (el) => {
    expect(groupById(el, "symbols")).toBeUndefined();
    expect(emptyProviders(el)).toBe("No matches in Symbols");
    expectEmptyLineLast(el);
    expect(groupById(el, "files").rows).toEqual(["fixtures/positive_field.toml", "fixtures/negative_field.toml"]);
    expect(groupById(el, "agent-harbor-search").rows.length).toBe(6);
    // A session matched by what it last said quotes it, so the match shows.
    const quoted = [...el.querySelectorAll('.ah-results-group[data-ah-group="agent-harbor-search"] .ah-results-second')]
      .map((q) => q.textContent);
    expect(quoted.length).toBeGreaterThan(0);
    for (const q of quoted) expect(q.toLowerCase()).toContain("field");
  }),
  "agent-harbor-results-search-none": resultsCheck(async (el) => {
    expect(resultsNotice(el)).toBe("Nothing matches “warp drive”");
    expect(el.querySelector(".ah-results-group")).toBeNull();
    expect(resultsHeader(el)).toBe("Searched 4 providers");
  }),
  "agent-harbor-results-search-long": resultsCheck(async (el) => {
    expect(groupById(el, "program-text").rows.length).toBe(8);
    expect(groupById(el, "program-text").more).toBe("+12 more");
    expect(el.querySelector('.ah-results-more[data-ah-target="program-text"]')?.dataset.ctOperation).toBe("results.more");
  }),
  "agent-harbor-results-search-group": resultsCheck(async (el) => {
    expect(groupsOf(el).map((g) => g.id)).toEqual(["program-text"]);
    expect(groupById(el, "program-text").rows.length).toBe(20);
    expect(groupById(el, "program-text").more).toBe("");
    expect(el.querySelector(".ah-results-back")?.textContent).toBe("← All providers");
    expect(resultsHeader(el)).toBe("Program text · 20 results · Enter opens");
    expect(el.querySelector(".ah-results-row-selected .ah-results-title").dataset.ahTitle).toBe("remaining_shield -= damage;");
    expectMatchedLinesWhole(el, "remaining");
    // The selection is the editor's selection ground, with the inset bar (D63).
    const sel = el.querySelector(".ah-results-row-selected");
    expect(getComputedStyle(sel).boxShadow).toContain("inset");
    expect(emptyProviders(el)).toBe("");
  }),
  "agent-harbor-results-search-superseded": resultsCheck(async (el) => {
    expect(resultsField(el)).toBe("/s shield_pct");
    expect(groupById(el, "program-text").word).toBe("searching…");
    // No row of the older `/s shield` stands under the newer query.
    expect(groupById(el, "files")).toBeUndefined();
    expect(emptyProviders(el)).toContain("Files");
    for (const g of groupsOf(el)) for (const t of g.rows) expect(t.toLowerCase()).toContain("shield_pct");
  }),
  "agent-harbor-results-ah-commands": resultsCheck(async (el) => {
    const cmds = groupById(el, "agent-harbor-commands");
    expect(cmds.rows).toEqual(["/ah-search", "/ah-search-chats", "/ah-specs"]);
    const tags = [...el.querySelectorAll(".ah-results-row .ah-results-tag")].map((t) => t.textContent);
    expect(tags).toEqual(["Agent Harbor", "Agent Harbor", "Spec index"]);
    expect([...el.querySelectorAll(".ah-results-row .ah-results-detail")].map((d) => d.textContent))
      .toEqual(["/ahs", "/ahsc", "/ahsp"]);
  }),
  "agent-harbor-results-ah-search": resultsCheck(async (el) => {
    expect(resultsHeader(el)).toBe("/ahs is /ah-search · Search sessions · Agent Harbor");
    expect(groupById(el, "search").rows[0]).toBe("Clamp the shield at zero after a hit");
  }),
  "agent-harbor-results-ah-unknown": resultsCheck(async (el) => {
    expect(resultsNotice(el)).toBe("No Agent Harbor command named /ah-sessions");
    expect(el.querySelector(".ah-results-notice-hint")?.textContent).toBe("/ah lists them");
    // The command's name is never split by a line break.
    expect(el.querySelector(".ah-results-term")?.textContent).toBe("/ah-sessions");
    expect(el.querySelector(".ah-results-group")).toBeNull();
  }),
  "agent-harbor-results-ah-unreachable": resultsCheck(async (el) => {
    expect(resultsNotice(el)).toBe("Agent Harbor is not reachable: GET /api/v1/input-commands failed: connection refused");
    expect(el.querySelector(".ah-results-notice.ah-role-error")).toBeTruthy();
    expect(el.querySelector(".ah-results-group")).toBeNull();
  }),
  "agent-harbor-results-ah-extension": resultsCheck(async (el) => {
    expect(resultsHeader(el)).toBe("/ahsp is /ah-specs · Search specs · Spec index");
    const tags = [...el.querySelectorAll(".ah-results-row .ah-results-tag")].map((t) => t.textContent);
    expect(tags).toEqual(["Spec index", "Spec index"]);
  }),
  "agent-harbor-results-rich-rows": resultsCheck(async (el) => {
    const frames = [...el.querySelectorAll("iframe.ah-results-box")];
    expect(frames.length).toBe(3);
    // Never same-origin; scripts only for the trusted (built-in) source.
    // The roles reach the frames once they are in the page.
    await waitUntil(() => frames.every((f) => (f.getAttribute("srcdoc") ?? "").includes("--ct-body:#")),
                    "the boxes filled with the page's roles");
    expect(frames.map((f) => f.getAttribute("sandbox"))).toEqual(["allow-scripts", "allow-scripts", ""]);
    for (const f of frames) expect(f.getAttribute("srcdoc")).toContain("default-src 'none'");
    // An untrusted box is given its HTML without its script.
    expect(frames[2].getAttribute("srcdoc")).not.toContain("getElementById('live')");
    // The tall box is held to the height its source asks (at most 12rem)
    // and scrolls inside.
    await waitUntil(() => Math.round(frames[1].getBoundingClientRect().height) === 120, "the tall box held to its height");
    expect(el.querySelector(".ah-results-note")?.textContent).toBe("Scripts are not run for this source");
    expect([...el.querySelectorAll(".ah-results-tag-html")].length).toBe(3);
    // A drawn box holds the row's words: no quoted line repeats them.
    for (const box of el.querySelectorAll(".ah-results-boxwrap")) {
      expect(box.closest(".ah-results-row").querySelector(".ah-results-second")).toBeNull();
    }
  }),
  "agent-harbor-results-text-fallback": resultsCheck(async (el) => {
    expect(el.querySelector("iframe.ah-results-box")).toBeNull();
    // The phrase is joined by no-break spaces: a narrow sheet wraps the
    // header between its parts.
    expect(resultsHeader(el)).toBe("4 results from 5 providers · Enter opens · Rich\u00a0results\u00a0shown\u00a0as\u00a0text");
    expect(groupById(el, "agent-harbor-search").rows.length).toBe(3);
    // Each rich row shows its text form instead of its box: its last
    // words, quoted under its title.
    const quoted = [...el.querySelectorAll('.ah-results-group[data-ah-group="agent-harbor-search"] .ah-results-second')]
      .map((n) => n.textContent);
    expect(quoted.length).toBe(3);
    for (const q of quoted) expect(q.startsWith("\u201c")).toBe(true);
    // The design note's too (a contributed provider's rich row).
    const notes = [...el.querySelectorAll('.ah-results-group:not([data-ah-group="agent-harbor-search"]) .ah-results-second')];
    expect(notes.map((n) => n.textContent.startsWith("\u201cThe damage is clamped"))).toEqual([true]);
  }),
  "agent-harbor-results-opened-outside": resultsCheck(async (el) => {
    expect(resultsHeader(el)).toBe("Opened outside CodeTracer: https://specs.noir-space-ship.example/shield-clamp");
    expect(el.querySelector(".ah-results-opened-outside")?.textContent).toBe("Opened outside CodeTracer");
  }),
  "agent-harbor-results-at-completion": resultsCheck(async (el) => {
    expect(resultsField(el)).toBe("/ai Run drained_field_fails again with @");
    expect(groupsOf(el).map((g) => g.id)).toEqual(["agents", "repositories", "files"]);
    expect(groupById(el, "agents").rows).toEqual(["@Claude", "@Codex", "@Grok", "@Opencode", "@Antigravity"]);
    expect(resultsHeader(el)).toBe("Completing @ · Tab inserts it");
  }),
  "agent-harbor-results-slash-completion": resultsCheck(async (el) => {
    expect(groupsOf(el).map((g) => g.id)).toEqual(["workflows", "capabilities"]);
    expect(groupById(el, "capabilities").rows).toEqual(["/research", "/think", "/stream"]);
  }),
};

// --- The Changes panel and the Inbox (CTF-P3) ------------------------------
//
// Their rows are cardless, as the timeline's lines are: an inbox row, a spec
// card, an item's page and the row layout inside each draw no border,
// outline or shadow, and no background but the panel's own ground. Two
// exceptions, each a mark of state rather than a box: the item on screen
// (`.ah-inbox-row-current`) is a selection, the raised fill with one inset
// bar in the action colour, and an open card (`.ah-card-open`) has the one
// inset bar and no fill. The parts that are not rows -- the state dot, the
// chips, buttons and fields -- are drawn with their own grounds and are not
// read. `rowProblems` reads the browser's computed styles.
const P3_ROWS = ".ah-inbox-row, .ah-spec-card, .ah-item-page";
const P3_ROW_PARTS = [
  ":scope > .ah-inbox-row-main",
  ":scope > .ah-inbox-row-main > .ah-inbox-row-line",
  ":scope > .ah-spec-card-head",
  ":scope > .ah-spec-card-body",
  ":scope > .ah-item-head",
].join(", ");
// One inset shadow and nothing else: `<colour> <x> <y> <blur> <spread>
// inset`, as the browser computes it. The colours' own commas are taken out
// first, so any comma left separates a second shadow, before or after the
// inset one.
const oneInsetBar = (shadow) => {
  const layers = shadow.replace(/rgba?\([^)]*\)/g, "c");
  return !layers.includes(",") && /\binset\b/.test(layers);
};
function rowProblems(panel) {
  const ground = getComputedStyle(panel).backgroundColor;
  const problems = [];
  for (const row of panel.querySelectorAll(P3_ROWS)) {
    const id = row.getAttribute("data-ah-item") || row.getAttribute("data-ah-card") || row.className;
    const selected = row.classList.contains("ah-inbox-row-current");
    const open = row.classList.contains("ah-card-open");
    for (const e of [row, ...row.querySelectorAll(P3_ROW_PARTS)]) {
      const cs = getComputedStyle(e);
      for (const side of ["Top", "Right", "Bottom", "Left"]) {
        if (parseFloat(cs[`border${side}Width`]) > 0 && cs[`border${side}Style`] !== "none") {
          problems.push(`${id}: a ${side.toLowerCase()} border on ${e.className}`);
        }
      }
      if (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) > 0) {
        problems.push(`${id}: an outline on ${e.className}`);
      }
      const filled = !TRANSPARENT.has(cs.backgroundColor) && cs.backgroundColor !== ground;
      if (filled && !(e === row && selected)) {
        problems.push(`${id}: the background ${cs.backgroundColor} on ${e.className}`);
      }
      if (cs.boxShadow !== "none" && !(e === row && (selected || open) && oneInsetBar(cs.boxShadow))) {
        problems.push(`${id}: the shadow ${cs.boxShadow} on ${e.className}`);
      }
    }
  }
  return problems;
}

// The check can fail: each of four copies of a drawn row, given one box --
// a 1px border, an outline, a drop shadow, a fill of its own -- is reported
// for it, and so is a fifth whose inset bar has a second shadow beside it;
// a copy given the selection (an inbox row) or opened (a card) is not. The
// boxes are planted on the row's first row-layout part when it has one, so
// the parts are read too. Every copy is removed at once, so the story is
// left as it stood.
const PLANTED_BOXES = [
  ["border", { border: "1px solid red" }, /border on/],
  ["outline", { outline: "1px solid red" }, /an outline on/],
  ["shadow", { boxShadow: "0 1px 2px red" }, /the shadow/],
  ["fill", { backgroundColor: "rgb(255, 0, 0)" }, /the background/],
  ["two-shadows", { boxShadow: "inset 3px 0 0 red, 0 1px 2px red" }, /the shadow/],
];
function rowControl(panel, row) {
  const asMark = row.classList.contains("ah-inbox-row") ? "ah-inbox-row-current"
    : row.classList.contains("ah-spec-card") ? "ah-card-open" : null;
  const copies = [];
  const plant = (id) => {
    const copy = row.cloneNode(true);
    copy.classList.remove("ah-inbox-row-current", "ah-card-open");
    copy.setAttribute("data-ah-item", id);
    copy.setAttribute("data-ah-card", id);
    copies.push(copy);
    return copy;
  };
  for (const [kind, style] of PLANTED_BOXES) {
    const copy = plant(`planted-${kind}`);
    const target = kind === "two-shadows" ? copy : (copy.querySelector(P3_ROW_PARTS) ?? copy);
    Object.assign(target.style, style);
  }
  if (asMark) plant("planted-mark").classList.add(asMark);
  row.parentElement.append(...copies);
  try {
    const found = rowProblems(panel);
    const missed = PLANTED_BOXES.filter(([kind, , says]) =>
      !found.some((p) => p.startsWith(`planted-${kind}:`) && says.test(p))).map(([kind]) => kind);
    expect(missed).toEqual([]);
    expect(found.filter((p) => p.startsWith("planted-mark:"))).toEqual([]);
  } finally {
    for (const c of copies) c.remove();
  }
}

// The form controls are the design system's (CTF-P3 step 3d): no native
// `select` or radio button anywhere in the panel, every checkbox the
// design system's (`.ct-checkmark`) over its visually hidden input, and a
// dropdown's value whole where the panel has room for it (wider than the
// 30rem at which the Changes panel shortens its labels).
const COMPACT_PANEL_PX = 30 * 16;
function controlProblems(panel) {
  const problems = [];
  for (const e of panel.querySelectorAll("select, input[type=radio]")) {
    problems.push(`a native ${e.tagName.toLowerCase()}${e.type === "radio" ? " radio" : ""}`);
  }
  for (const e of panel.querySelectorAll("input[type=checkbox]")) {
    if (!e.classList.contains("ct-checkmark-input") ||
        !e.nextElementSibling?.classList.contains("ct-checkmark")) {
      problems.push(`a native checkbox (${e.className || "no class"})`);
    }
  }
  const roomy = panel.getBoundingClientRect().width > COMPACT_PANEL_PX;
  for (const v of panel.querySelectorAll(".ah-dropdown-value")) {
    if (v.textContent.endsWith("\u2026")) problems.push(`a dropdown reads "${v.textContent}"`);
    // A value cut to nothing (its box collapsed to no width) is cut too;
    // only a dropdown that is not drawn at all is left out.
    if (roomy && shownEl(v.closest(".ah-dropdown")) && v.scrollWidth > v.clientWidth + 1) {
      problems.push(`the dropdown value "${v.textContent}" is cut where the panel has room`);
    }
  }
  return problems;
}

// A Changes or Inbox story: its panel drawn in its declared state, its rows
// cardless (with the control, wherever a row is drawn), its form controls
// the design system's, and, where `rows` says the story is for its rows,
// at least one drawn. Returns the panel.
async function changesInboxChecks(canvasElement, selector, { rows = false } = {}) {
  const panel = await waitFor(canvasElement, selector);
  await tick();
  const drawn = panel.querySelectorAll(P3_ROWS);
  if (rows) expect(drawn.length).toBeGreaterThan(0);
  expect(rowProblems(panel)).toEqual([]);
  const row = panel.querySelector(".ah-inbox-row, .ah-spec-card") ?? drawn[0];
  if (row) rowControl(panel, row);
  expect(controlProblems(panel)).toEqual([]);
  return panel;
}

// A visible element: laid out with an area, not hidden by its own display.
const shownEl = (e) => !!e && e.getBoundingClientRect().width > 0 &&
  getComputedStyle(e).display !== "none";

// The Code tab's marks (step 3d): each short mark (`C`, `U`, `C+U`,
// `key`) with its tooltip, and the legend over the files saying what they
// stand for.
function codeMarkProblems(panel) {
  const problems = [];
  const marks = [...panel.querySelectorAll(".ah-origin-mark, .ah-key-mark, .ah-binary-mark")];
  if (marks.length === 0) return problems;
  for (const m of marks) {
    if (!(m.getAttribute("title") ?? "").trim()) problems.push(`the mark "${m.textContent}" has no tooltip`);
  }
  const legend = panel.querySelector(".ah-code-legend");
  if (!shownEl(legend)) problems.push("no legend saying what the marks stand for");
  else if (!/^C committed/.test(legend.textContent)) problems.push(`the legend reads "${legend.textContent}"`);
  return problems;
}

// The inbox's hint (step 3d): while items wait and none is on screen (no
// row selected and no item's page: an item answered elsewhere keeps its
// page though its row has gone), the page's place says how to put one
// there; otherwise no hint. That nothing is opened to fill the place is
// the viewmodel's rule, held by `test_inbox_vm`.
function inboxHintProblems(panel) {
  const rows = panel.querySelectorAll(".ah-inbox-row");
  const onScreen = panel.querySelector(".ah-inbox-row-current, .ah-item-page");
  const hint = panel.querySelector(".ah-inbox-hint");
  if (rows.length === 0) return hint ? ["a hint with nothing waiting"] : [];
  if (onScreen) return hint ? ["a hint beside the item on screen"] : [];
  const problems = [];
  if (!shownEl(hint)) problems.push("no hint while items wait and none is on screen");
  else if (!/^Select an item/.test(hint.textContent)) problems.push(`the hint reads "${hint.textContent}"`);
  return problems;
}

// An item's page (step 3d): a queued approval's command on a line of its
// own in code (Space Mono), its purpose apart; every form button compact;
// and, on a pane wider than the reading measure, every part kept to it and
// centred.
const READING_PX = 48 * 16;
// A form button's padding and border each side (`ct-button-sm-*`: 7.5px
// and a hairline) with room to spare; a button wider than its label by more
// than this has been stretched across the column it stands in.
const BUTTON_CHROME_PX = 32;
function itemPageProblems(panel) {
  const problems = [];
  // Every form button (`Send draft` in a draft included) stands in an
  // actions row (`.ah-item-actions`) at its label's width, as `Submit`
  // does: a button put in a column directly is stretched across it.
  for (const b of panel.querySelectorAll(".ah-item-action")) {
    if (!shownEl(b)) continue;
    const label = b.textContent.trim();
    if (!b.parentElement?.classList.contains("ah-item-actions")) problems.push(`the button "${label}" is not in an actions row`);
    const text = document.createRange();
    text.selectNodeContents(b);
    const textPx = text.getBoundingClientRect().width;
    const width = b.getBoundingClientRect().width;
    if (width > textPx + BUTTON_CHROME_PX) {
      problems.push(`the button "${label}" is ${Math.round(width)}px wide for a ${Math.round(textPx)}px label (stretched)`);
    }
  }
  for (const a of panel.querySelectorAll(".ah-item-approval")) {
    const subject = a.querySelector(".ah-item-approval-subject");
    if (!subject) { problems.push("an approval with no command line"); continue; }
    if (/ in order to/.test(subject.textContent)) problems.push(`the command runs on into its purpose: "${subject.textContent}"`);
    if (!/Space ?Mono/i.test(getComputedStyle(subject).fontFamily)) problems.push("the command is not in code style");
    const purpose = a.querySelector(".ah-item-approval-purpose");
    if (purpose && /Space ?Mono/i.test(getComputedStyle(purpose).fontFamily)) problems.push("the purpose is set as code");
  }
  for (const page of panel.querySelectorAll(".ah-item-page")) {
    const pr = page.getBoundingClientRect();
    if (pr.width <= READING_PX + 16) continue;
    for (const part of page.children) {
      const r = part.getBoundingClientRect();
      if (r.width === 0) continue;
      if (r.width > READING_PX + 0.5) problems.push(`a page part ${r.width}px wide, past the reading measure`);
      const left = r.left - pr.left, right = pr.right - r.right;
      if (Math.abs(left - right) > 2) problems.push(`a page part not centred (${left}px left, ${right}px right)`);
    }
  }
  return problems;
}

// Keys, as a reader presses them on the panel (the StoryBook mounts' key
// listener, `stories/dom_changes_inbox_keys.nim`): a keydown that bubbles
// from `target`; answers whether the listener took it (ran an operation).
async function pressKey(target, key, code = key) {
  const ev = new KeyboardEvent("keydown", { key, code, bubbles: true, cancelable: true });
  target.dispatchEvent(ev);
  await tick();
  return ev.defaultPrevented;
}
const twoFrames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));

// The scrolling region `el` lies in: its nearest ancestor that scrolls and
// holds more than it shows (null for none).
function scrollerOf(el) {
  let p = el?.parentElement;
  while (p && !(p.scrollHeight > p.clientHeight && /(auto|scroll)/.test(getComputedStyle(p).overflowY))) {
    p = p.parentElement;
  }
  return p ?? null;
}

// Whether `el` lies in its scrolling region's window: its top shown, and
// all of it when it fits.
function inRegionView(el) {
  const p = scrollerOf(el);
  if (!p) return true;
  const er = el.getBoundingClientRect(), pr = p.getBoundingClientRect();
  return er.top >= pr.top - 1 && Math.min(er.bottom, er.top + pr.height) <= pr.bottom + 1;
}

// The inbox's Previous / Next group: its position is the viewmodel's
// (`3 of 5` mid-walk), and each step is enabled or disabled as the story
// says. The position names the row on screen: the one selected row is the
// row at that place in the drawn order, there are as many rows as the
// position counts, and the explanation strip over the item's page opens
// with the same position. So a step that landed on another item, or a
// group that shows a position the rows do not, fails here even though the
// check presses nothing.
function stepperIs(panel, position, { prev, next }) {
  const stepper = panel.querySelector(".ah-inbox-stepper");
  expect(stepper?.getAttribute("data-ah-position")).toBe(position);
  expect(stepper.querySelector(".ah-step-position")?.textContent).toBe(position);
  expect(stepper.querySelector(".ah-step-prev").disabled).toBe(!prev);
  expect(stepper.querySelector(".ah-step-next").disabled).toBe(!next);
  const [at, of] = position.split(" of ").map(Number);
  const rows = [...panel.querySelectorAll(".ah-inbox-row")];
  expect(rows.length).toBe(of);
  const current = rows.filter((r) => r.classList.contains("ah-inbox-row-current"));
  expect(current.length).toBe(1);
  expect(rows.indexOf(current[0]) + 1).toBe(at);
  expect(current[0].getAttribute("data-ah-position")).toBe(String(at));
  expect(panel.querySelector(".ah-item-page")).toBeTruthy();
  expect(panel.querySelector(".ah-inbox-strip")?.getAttribute("data-ah-strip") ?? "")
    .toMatch(new RegExp(`^${position} \u00b7 `));
}

const changesPanel = ".agent-harbor-changes";
const inboxPanel = ".agent-harbor-inbox";
const inboxItemPanel = ".agent-harbor-inbox-item";


// The suggested-actions block at a session timeline's end (CTF-P2c step 3,
// src/frontend/stories/agent_harbor_suggested_actions_stories.nim): the
// timeline's own checks, then the block's facts. `suggestedRows` reads each
// action's facts; the block is null once the suggestion is decided.
const suggestedBlock = (panel) => panel.querySelector('.ah-suggested[data-ah-suggested="block"]');
const suggestedRows = (panel) => [...panel.querySelectorAll(".ah-suggested-row")].map((r) => ({
  id: r.getAttribute("data-ah-suggested-action"),
  text: r.querySelector(".ah-suggested-words")?.textContent ?? "",
  checked: r.getAttribute("data-ah-action-checked") === "true",
  disabled: r.getAttribute("data-ah-action-disabled") === "true",
  dimmed: r.getAttribute("data-ah-action-dimmed") === "true",
  reason: r.querySelector(".ah-suggested-why")?.textContent ?? "",
  operation: r.getAttribute("data-ct-operation"),
  target: r.getAttribute("data-ah-target"),
}));
const recordLines = (panel) => [...panel.querySelectorAll('[data-ah-item-kind="ui-action"], [data-ah-item-kind="ui-action-outcome"]')].map((l) => ({
  text: l.getAttribute("data-ah-text"),
  level: Number(l.getAttribute("data-ah-level")),
  role: l.getAttribute("data-ah-role"),
}));
function suggestedCheck(assert) {
  return async ({ canvasElement }) => {
    const panel = await activityChecks(canvasElement);
    expect(panel.getAttribute("data-ah-state")).toBe("ready");
    // The drained-field session's timeline, the agent's question last.
    expect(panel.querySelector('[data-ah-item-kind="question"]')?.getAttribute("data-ah-text"))
      .toContain("drained_field_fails expect the shield at exactly 0");
    const block = suggestedBlock(panel);
    if (block) {
      // On the raised ground the Running strip uses, pinned under the list:
      // the list scrolls, the block does not.
      const list = panel.querySelector(".ah-activity-lines");
      expect(list.contains(block)).toBe(false);
      expect(block.parentElement).toBe(list.parentElement);
      expect(getComputedStyle(block).backgroundColor).not.toBe(getComputedStyle(panel).backgroundColor);
      expect(block.querySelector(".ah-suggested-label")?.textContent).toBe("SUGGESTED UI ACTIONS");
      expect(block.querySelector(".ah-suggested-reason")?.textContent)
        .toBe("Look at the drained-field test's recording at pass 5 before deciding what it should expect.");
      for (const row of suggestedRows(panel)) {
        if (row.disabled) {
          expect(row.checked).toBe(false);
          expect(row.operation).toBeNull();
          expect(row.reason.length).toBeGreaterThan(0);
        } else {
          expect(row.operation).toBe("suggested-actions.toggle");
          expect(row.target).toBe(row.id);
        }
      }
      // An action's words wrap; they are never cut.
      expect(block.querySelector(".ah-suggested-words[data-ah-cut]")).toBeNull();
    }
    await assert(panel, block);
  };
}
// A press on a row toggles it through the router, and the label follows;
// a second press puts it back, so the story is left as it stood.
async function toggleRoundTrip(panel, id, labelAfter) {
  const before = suggestedBlock(panel).getAttribute("data-ah-approve-label");
  panel.querySelector(`.ah-suggested-row[data-ah-target="${id}"]`).click();
  await waitUntil(() => suggestedBlock(panel)?.getAttribute("data-ah-approve-label") === labelAfter,
    `the label ${labelAfter} after unchecking ${id}`);
  panel.querySelector(`.ah-suggested-row[data-ah-target="${id}"]`).click();
  await waitUntil(() => suggestedBlock(panel)?.getAttribute("data-ah-approve-label") === before,
    `the label ${before} again`);
}

// --- The control center and the gaze mark (CTF-P2c step 4) ---------------
//
// The control center: launching on the left, the Initiatives panel and the
// sessions waiting for the operator on the right, one column under 720px
// (`data-ah-columns`); every fact is the view's own (`centerFacts`).
// A computed colour's channels and alpha (`rgb(...)` / `rgba(...)`): the
// ring check walks out to the first opaque grounds; `contrastOf` (above)
// measures it.
function rgbOf(css) {
  const m = css.match(/rgba?\(([^)]+)\)/);
  if (!m) return [0, 0, 0, 0];
  const p = m[1].split(/[ ,\/]+/).filter(Boolean).map(Number);
  return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1];
}

// A ringed button's ring (1px clear, 2px wide: 3px out from its outline)
// stays clear of each neighbouring button by at least that much again, 3px
// (D81, the coordinator's follow-up to the step-4 batch review): the ring
// reads as its own button's, not as shared with the next.
function expectRingClear(el) {
  const own = el.getBoundingClientRect();
  for (const nb of [el.previousElementSibling, el.nextElementSibling]) {
    if (!nb || !nb.matches(".ah-rec-button, .ah-rec-more")) continue;
    const r = nb.getBoundingClientRect();
    const between = r.left >= own.right ? r.left - own.right : own.left - r.right;
    expect(between - 3).toBeGreaterThanOrEqual(3);
  }
}

const centerOf = (el) => el.querySelector(".ah-control-center");
const waitingIds = (center) => [...center.querySelectorAll(".ah-cc-waiting-row")]
  .map((r) => r.getAttribute("data-ah-waiting-session"));
const waitingTitles = (center) => [...center.querySelectorAll(".ah-cc-waiting-row")]
  .map((r) => r.getAttribute("data-ah-waiting-title"));
const pressedModes = (center) => [...center.querySelectorAll(".ah-cc-modes .ah-composer-toggle")]
  .map((b) => [b.textContent, b.getAttribute("aria-pressed")]);

function centerCheck(assert) {
  return async ({ canvasElement }) => {
    const center = await waitFor(canvasElement, ".ah-control-center");
    // One column, launching first, below 720px; two columns otherwise.
    const columns = center.getBoundingClientRect().width < 720 ? "one" : "two";
    expect(center.getAttribute("data-ah-columns")).toBe(columns);
    const launch = center.querySelector(".ah-cc-launch");
    const overview = center.querySelector(".ah-cc-overview");
    const [l, o] = [launch.getBoundingClientRect(), overview.getBoundingClientRect()];
    if (columns === "one") expect(o.top).toBeGreaterThanOrEqual(l.bottom - 1);
    else expect(o.left).toBeGreaterThanOrEqual(l.right - 1);
    expect(launch.getAttribute("data-ct-pane")).toBe("composer");
    expect(center.getAttribute("data-ct-pane")).toBe("controlCenter");
    // The answer is never split at a path's or a host's `-` or `/`: such a
    // word is whole on one line where the line can hold it.
    const noticeLine = center.querySelector(".ah-cc-notice-line");
    if (noticeLine) {
      for (const w of noticeLine.querySelectorAll(".ah-cc-nobreak")) {
        if (w.getBoundingClientRect().width < noticeLine.clientWidth) {
          expect(w.getClientRects().length).toBe(1);
          expect(w.getBoundingClientRect().height).toBeLessThanOrEqual(17);
        }
      }
    }
    // Each column opens with a panel's head band, the Initiatives panel's
    // own (study D73), so the heads line up.
    expect(center.querySelector(".ah-cc-launch .ah-fleet-head .ah-fleet-title")?.textContent).toBe("Launch");
    // The waiting rows carry their operation and no dot of their own.
    for (const row of center.querySelectorAll(".ah-cc-waiting-row")) {
      expect(row.getAttribute("data-ct-operation")).toBe("control-center.open-session");
      expect(row.querySelector(".ah-fleet-dot, .ah-tab-mark, .ah-pie")).toBeNull();
      expect(row.getAttribute("aria-label")).toContain(row.getAttribute("data-ah-waiting-words"));
    }
    // No field of the launch form cuts what it shows (manager note 167: at a
    // panel's width the half-width Session name read `named by the serv…`):
    // below 30rem of column the fields take a row each, as GPUI's and the
    // terminal's do.
    for (const value of center.querySelectorAll(".ah-cc-form .ah-composer-field-value")) {
      expect(value.scrollWidth).toBeLessThanOrEqual(value.clientWidth + 1);
    }
    await assert(center, canvasElement);
  };
}

// A multi-process recording's session tab with its process switcher
// (CTF-P2c step 5, study §2.6 and D25): the recording's tab, active, holds
// the recording switcher's buttons for its processes. A narrow window
// (below 720px) draws the first process and the active one before +N.
const processTab = (el) => el.querySelector(".ah-ps-bar .ah-ps-tab");
function processCheck(assert) {
  return async ({ canvasElement }) => {
    await waitFor(canvasElement, ".ah-ps-bar .ah-ps-tab .ah-rec-button");
    const tab = processTab(canvasElement);
    expect(tab.classList.contains("active")).toBe(true);
    expect(tab.querySelector(".session-tab-label").textContent).toBe("envelope-flow");
    expect(tab.querySelector(".ah-ps-processes").getAttribute("data-ct-pane")).toBe("processSwitcher");
    expect(tab.getAttribute("title")).toContain("Ctrl+Alt+PageDown / Ctrl+Alt+PageUp to move between them");
    const tabs = canvasElement.querySelectorAll(".ah-ps-bar .session-tab");
    expect(tabs.length).toBe(2);
    expect(tabs[1].textContent).toBe("sudoku");
    await assert(tab, window.innerWidth < 720);
  };
}
const processButtons = (tab) => [...tab.querySelectorAll(".ah-rec-button")];

const gazeHost = (el) => el.querySelector(".ah-gaze-host");
function gazeCheck(assert) {
  return async ({ canvasElement }) => {
    await waitFor(canvasElement, "#status .status-right .ah-gaze-host");
    // In context (manager note 167): the status line under the control
    // center, as L7 shows it.
    const center = await waitFor(canvasElement, ".ah-gaze-story .ah-control-center");
    expect(center.getBoundingClientRect().bottom)
      .toBeLessThanOrEqual(canvasElement.querySelector("#status").getBoundingClientRect().top + 1);
    await assert(gazeHost(canvasElement), canvasElement);
  };
}

const centerChecks = {
  "agent-harbor-control-center-populated": centerCheck(async (center) => {
    expect(center.getAttribute("data-ah-cc-state")).toBe("asReady");
    expect(pressedModes(center)).toEqual([["New task", "true"], ["New initiative", "false"]]);
    // The Initiatives panel, the same view, with the project's four initiatives.
    const panel = center.querySelector(".ah-cc-initiatives .agent-harbor-initiatives");
    expect(panel).toBeTruthy();
    expect(panel.querySelectorAll(".ah-initiative-row").length).toBe(4);
    // In inbox order: the two questions, the longest waiting first, then the
    // ended turn.
    expect(waitingTitles(center)).toEqual([
      "Make calculate_damage safe for masses above u32",
      "Fix the negative-field test that times out on macOS",
      "Write the 0.4 changelog"]);
    // What waits for the operator comes first, then the initiatives (D73).
    const waiting = center.querySelector(".ah-cc-waiting");
    expect(waiting.querySelector(".ah-fleet-title").textContent).toBe("Waiting for you");
    expect(waiting.querySelector(".ah-cc-waiting-count").textContent).toBe("3 sessions");
    expect(waiting.getBoundingClientRect().top)
      .toBeLessThan(center.querySelector(".ah-cc-initiatives").getBoundingClientRect().top);
    expect([...center.querySelectorAll(".ah-cc-recent-row")].map((r) => r.getAttribute("data-ah-recent-launch")))
      .toEqual(["Asteroid fields generated from seeds, end to end",
                "Make the regeneration cap configurable per ship"]);
    // The empty field's send line asks for the instruction, beside a
    // disabled Launch. (Presses and keys are the routing test's,
    // test_ctf_p2c_control_center_operations: a play check that pressed
    // here would leave its marks in the story's captures.)
    expect(center.querySelector(".ah-cc-send .ah-composer-send-hint").textContent)
      .toBe("Type the instruction to launch");
    expect(center.querySelector(".ah-cc-send .ah-composer-send-button").disabled).toBe(true);
  }),
  "agent-harbor-control-center-empty": centerCheck(async (center) => {
    expect(center.getAttribute("data-ah-cc-empty")).toBe("true");
    // A disabled `Launch` over an empty field is not busy: no spinner.
    const idle = center.querySelector(".ah-cc-send .ah-composer-send-button");
    expect(idle.disabled).toBe(true);
    expect(idle.getAttribute("aria-busy")).toBeNull();
    expect(idle.querySelector(".ah-busy-spinner")).toBeNull();
    expect(center.querySelector(".ah-cc-empty-line")?.textContent).toBe("No initiatives yet.");
    expect(getComputedStyle(center.querySelector(".ah-cc-initiatives")).display).toBe("none");
    expect(center.querySelector('.ah-cc-form [data-ah-field="Repository"]')).toBeTruthy();
  }),
  "agent-harbor-control-center-launching": centerCheck(async (center) => {
    // Launch pressed, Agent Harbor not answering yet (D70, D74): the form
    // drawn as it was sent and locked, Launch busy and disabled,
    // `Launching…` in the body role where the answer will go.
    expect(center.getAttribute("data-ah-cc-launching")).toBe("true");
    expect(center.getAttribute("data-ah-cc-launch-for")).toBe("Shield model hardening");
    const field = center.querySelector(".ah-cc-input");
    expect(field.value).toBe("Add a test for a hit on an empty shield");
    expect(field.readOnly).toBe(true);
    const form = center.querySelector(".ah-cc-form");
    expect(form.getAttribute("data-ah-locked")).toBe("true");
    expect(form.querySelector('[data-ah-field="Branch"]')?.textContent).toContain("test/empty-shield");
    for (const t of center.querySelectorAll(".ah-cc-launch .ah-composer-toggle")) {
      expect(t.disabled).toBe(true);
    }
    const button = center.querySelector(".ah-cc-send .ah-composer-send-button");
    expect(button.textContent).toBe("Launch");
    expect(button.disabled).toBe(true);
    expect(button.getAttribute("aria-busy")).toBe("true");
    // Busy is seen, not only announced: the design system's spinner before
    // the label, in the action colour's ring step at 3:1 or more on the
    // panel; the plain disabled `Launch` (ControlCenterEmpty) draws none.
    const spinner = button.querySelector(".ah-busy-spinner");
    expect(spinner).toBeTruthy();
    const spin = getComputedStyle(spinner);
    expect(spin.display).not.toBe("none");
    expect(spinner.getBoundingClientRect().width).toBeGreaterThan(0);
    let panel = "rgb(255, 255, 255)";
    for (let g = button; g; g = g.parentElement) {
      const bg = getComputedStyle(g).backgroundColor;
      if (rgbOf(bg)[3] > 0) { panel = bg; break; }
    }
    expect(contrastOf(spin.borderTopColor, panel)).toBeGreaterThanOrEqual(3);
    expect(center.querySelector(".ah-cc-send .ah-composer-send-hint").textContent).toBe("");
    const notice = center.querySelector(".ah-cc-notice-line");
    expect(notice?.textContent).toBe("Launching\u2026");
    expect(notice.classList.contains("ah-role-body")).toBe(true);
    // What is being launched stays above what was not chosen (D74, follow-up
    // review): the locked values and the instruction, in the label role,
    // stand off their ground further than an option not chosen does, in
    // both themes (the caption role, 3.55:1 in Light, fell under the
    // disabled role's 3.73:1).
    const groundOf = (el) => {
      for (let g = el; g; g = g.parentElement) {
        const bg = getComputedStyle(g).backgroundColor;
        if (rgbOf(bg)[3] > 0) return bg;
      }
      return "rgb(255, 255, 255)";
    };
    const inkOn = (el) => contrastOf(getComputedStyle(el).color, groundOf(el));
    const notChosen = form.querySelector(".ah-composer-toggle:not(.active)");
    expect(notChosen).toBeTruthy();
    const floor = inkOn(notChosen);
    // The schedule's disclosure is not one to open while locked: its fold
    // in the disabled role, as an option not chosen.
    const fold = form.querySelector(".ah-composer-fold");
    expect(fold).toBeTruthy();
    expect(getComputedStyle(fold).color).toBe(getComputedStyle(notChosen).color);
    // The schedule's summary is part of what is launched: the label role, as
    // the form's values.
    const scheduleSummary = form.querySelector(".ah-composer-schedule-summary");
    expect(scheduleSummary).toBeTruthy();
    expect(inkOn(scheduleSummary)).toBeGreaterThan(floor);
    const values = [field, ...form.querySelectorAll(".ah-composer-field-value:not(.ah-composer-field-empty)")];
    expect(values.length).toBeGreaterThan(2);
    for (const v of values) expect(inkOn(v)).toBeGreaterThan(floor);
  }),
  "agent-harbor-control-center-launch-failed": centerCheck(async (center) => {
    // Refused (D74): `Could not launch: …` in the error role, the
    // instruction back in the field, the form open and Launch ready.
    expect(center.getAttribute("data-ah-cc-launching")).toBe("false");
    const notice = center.querySelector(".ah-cc-notice-line");
    expect(notice?.textContent).toBe("Could not launch: hub-a has no executor free for noir-space-ship");
    expect(notice.classList.contains("ah-role-error")).toBe(true);
    const field = center.querySelector(".ah-cc-input");
    expect(field.value).toBe("Add a test for a hit on an empty shield");
    expect(field.readOnly).toBe(false);
    expect(center.querySelector('.ah-cc-form [data-ah-field="Repository"]')).toBeTruthy();
    expect(center.querySelector(".ah-cc-send .ah-composer-send-button").disabled).toBe(false);
  }),
  "agent-harbor-control-center-launched": centerCheck(async (center) => {
    // The form is ready for the next launch, the answer under it (D74).
    expect(center.querySelector('.ah-cc-form [data-ah-field="Repository"]')).toBeTruthy();
    expect(center.querySelector(".ah-cc-send .ah-composer-send-button").disabled).toBe(true);
    expect(center.querySelector(".ah-cc-recent-row")?.getAttribute("data-ah-recent-launch"))
      .toBe("Add a test for a hit on an empty shield");
    const notice = center.querySelector(".ah-cc-notice-line");
    expect(notice?.textContent).toBe("Started on hub-a \u00b7 executor ws-ada \u00b7 session 8c1a13");
    expect(notice.classList.contains("ah-role-body")).toBe(true);
    expect(center.getAttribute("data-ah-cc-launch-for")).toBe("Shield model hardening");
    // The new session, queued, under its initiative in the Initiatives panel.
    const row = [...center.querySelectorAll(".ah-initiative-row")]
      .find((r) => r.textContent.includes("Shield model hardening"));
    expect(row?.textContent).toContain("Add a test for a hit on an empty shield");
    expect(waitingIds(center)).not.toContain("5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a13");
  }),
  "agent-harbor-control-center-loading": centerCheck(async (center) => {
    expect(center.getAttribute("data-ah-cc-state")).toBe("asLoading");
    expect(center.querySelector(".ah-cc-waiting").children.length).toBe(0);
    expect(center.querySelector('.ah-cc-form [data-ah-field="Repository"]')).toBeTruthy();
  }),
  "agent-harbor-control-center-error": centerCheck(async (center) => {
    expect(center.getAttribute("data-ah-cc-state")).toBe("asError");
    expect(center.querySelector(".ah-cc-initiatives").textContent).toContain("Could not load the initiatives");
    expect(center.querySelector(".ah-cc-waiting").children.length).toBe(0);
  }),
  "agent-harbor-status-gaze-off": gazeCheck(async (host) => {
    expect(host.getAttribute("data-ah-gaze")).toBe("off");
    expect(host.querySelector(".ah-gaze-mark")).toBeNull();
  }),
  "agent-harbor-status-gaze-tracking": gazeCheck(async (host) => {
    const mark = host.querySelector(".ah-gaze-mark");
    expect(mark.querySelector(".ah-gaze-text").textContent).toBe("Gaze");
    expect(mark.getAttribute("title")).toContain("Ctrl+Alt+Y pauses it.");
    expect(mark.getAttribute("data-ct-operation")).toBe("gaze.toggle-pause");
    expect(mark.querySelector("svg")).toBeTruthy();
    // The pause key pauses it, and again resumes it: the story ends as it
    // began.
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "y", code: "KeyY", ctrlKey: true, altKey: true }));
    await waitUntil(() => host.getAttribute("data-ah-gaze") === "paused", "paused by the key");
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "y", code: "KeyY", ctrlKey: true, altKey: true }));
    await waitUntil(() => host.getAttribute("data-ah-gaze") === "tracking", "resumed by the key");
  }),
  "agent-harbor-status-gaze-paused": gazeCheck(async (host) => {
    const mark = host.querySelector(".ah-gaze-mark");
    expect(mark.querySelector(".ah-gaze-text").textContent).toBe("Gaze paused");
    expect(mark.classList.contains("ah-gaze-paused")).toBe(true);
    expect(mark.getAttribute("title")).toContain("Ctrl+Alt+Y resumes it.");
    expect(mark.querySelectorAll("svg path").length).toBe(2);   // struck through
  }),
  "agent-harbor-process-switcher-three": processCheck(async (tab, narrow) => {
    const buttons = processButtons(tab);
    expect(buttons.map((b) => b.textContent)).toEqual(narrow ? ["1", "2"] : ["1", "2", "3"]);
    expect(buttons[0].classList.contains("ah-rec-active")).toBe(true);
    expect(buttons[1].getAttribute("title")).toBe("backend \u00b7 pid 4182 \u00b7 /srv/envelope/bin/backend");
    expect(tab.getAttribute("data-ah-process-ringed")).toBe("0");
    // The next-process key moves to process 2 and the previous-process key
    // back: the story ends as it began.
    const keyOf = (key) => new KeyboardEvent("keydown", { key, code: key, ctrlKey: true, altKey: true });
    window.dispatchEvent(keyOf("PageDown"));
    await waitUntil(() => processTab(document).getAttribute("data-ah-process-active") === "2", "moved by the key");
    window.dispatchEvent(keyOf("PageUp"));
    await waitUntil(() => processTab(document).getAttribute("data-ah-process-active") === "1", "moved back");
  }),
  "agent-harbor-process-switcher-correlation": processCheck(async (tab) => {
    // Process 2 is ringed until the reader goes there: the switcher's own
    // ring (study D81), the tab's fact and its button's tooltip.
    expect(tab.getAttribute("data-ah-process-ringed")).toBe("2");
    const ringed = processButtons(tab).filter((b) => b.classList.contains("ah-rec-ringed"));
    expect(ringed.map((b) => b.textContent)).toEqual(["2"]);
    // The ring (D81, manager note 239): a 2px outline 1px clear of the
    // button, at 3:1 or more against the tab's fill under it and against the
    // bar the tab sits in (WCAG 2.2 SC 1.4.11).
    const ringStyle = getComputedStyle(ringed[0]);
    expect(ringStyle.outlineStyle).toBe("solid");
    expect(ringStyle.outlineWidth).toBe("2px");
    expect(ringStyle.outlineOffset).toBe("1px");
    const grounds = [];
    for (let el = ringed[0].parentElement; el && grounds.length < 2; el = el.parentElement) {
      const bg = getComputedStyle(el).backgroundColor;
      if (rgbOf(bg)[3] > 0 && (grounds.length === 0 || bg !== grounds[0])) grounds.push(bg);
    }
    expectRingClear(ringed[0]);
    expect(grounds.length).toBe(2);   // the tab's fill, then the bar
    for (const ground of grounds) {
      expect(contrastOf(ringStyle.outlineColor, ground)).toBeGreaterThanOrEqual(3);
    }
    expect(tab.getAttribute("data-ah-process-active")).toBe("1");
    expect(processButtons(tab)[1].getAttribute("title"))
      .toContain("a correlation marker (envelope-flow, step 1 204) leads here");
  }),
  "agent-harbor-process-switcher-many": processCheck(async (tab, narrow) => {
    expect(tab.getAttribute("data-ah-processes")).toBe("8");
    expect(processButtons(tab).length).toBe(narrow ? 2 : 5);
    const more = tab.querySelector(".ah-rec-more");
    expect(more.textContent).toBe(narrow ? "+6" : "+3");
    // The failed worker is behind +N: the chip takes its error severity.
    expect(more.classList.contains("ah-att-failed")).toBe(true);
    // Its tooltip names what it hides: processes, not recordings.
    expect(more.getAttribute("title")).toMatch(/^\d+ more processes, 1 failed to load/);
  }),
  "agent-harbor-process-switcher-many-ringed": processCheck(async (tab, narrow) => {
    // The marker leads to process 8, behind +N at every size: no shown
    // button is ringed, the chip carries the ring (D80) at its weight
    // (D81, manager note 239) and the tab says which process.
    expect(tab.getAttribute("data-ah-process-ringed")).toBe("8");
    expect(processButtons(tab).filter((b) => b.classList.contains("ah-rec-ringed")).length).toBe(0);
    const more = tab.querySelector(".ah-rec-more");
    expect(more.textContent).toBe(narrow ? "+6" : "+3");
    expect(more.classList.contains("ah-rec-ringed")).toBe(true);
    const ring = getComputedStyle(more);
    expect(ring.outlineStyle).toBe("solid");
    expect(ring.outlineWidth).toBe("2px");
    expect(ring.outlineOffset).toBe("1px");
    expectRingClear(more);
  }),
  "agent-harbor-process-switcher-loading-and-missing": processCheck(async (tab, narrow) => {
    const buttons = processButtons(tab);
    expect(buttons[1].classList.contains("ah-rec-loading")).toBe(true);
    expect(buttons[1].getAttribute("title")).toContain("(loading)");
    if (!narrow) {
      expect(buttons[2].classList.contains("ah-rec-missing")).toBe(true);
      expect(buttons[2].getAttribute("title")).toContain("(missing: not in the recording's bundle)");
    } else {
      // The missing worker is behind +1: the chip takes the warning severity.
      expect(tab.querySelector(".ah-rec-more").classList.contains("ah-att-needs-input")).toBe(true);
    }
  }),
  // L7: the control center itself, under the caption tabs.
  "layout-l7-control-center": async ({ canvasElement }) => {
    const center = await waitFor(canvasElement, ".ah-control-center", 30000);
    expect(center.closest(".ah-control-center-tab")).toBeTruthy();
    expect(center.querySelectorAll(".ah-cc-waiting-row").length).toBe(3);
    // The stand-ins are gone: no Initiative Progress panel, no docked session list.
    expect(canvasElement.querySelector(".agent-harbor-progress")).toBeNull();
    expect(canvasElement.querySelector(".ah-session-list")).toBeNull();
  },
};

export const plays = {
  ...centerChecks,
  ...composerChecks,
  ...resultsChecks,
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
    // Probed on a failed row that has an activity line: a failed session
    // need not have one (the captured snapshot's first failed row has a
    // failure line and no recent activity), so the first failed row is not
    // necessarily one. The story must hold at least one such row.
    const probeRow = withFailure.find((r) => r.querySelector(".ah-fleet-activity-line"));
    expect(probeRow, "a failed row with an activity line").toBeTruthy();
    const probe = probeRow.querySelector(".ah-fleet-activity-line");
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
    await overflowMenuHangs(el, ".ah-tab-strip:not(.ah-initiative-tab-bar)");
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

  "agent-harbor-initiative-tabs": initiativeTabsCheck(initiativeTabsDrawn),
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
    expect(item.getAttribute("title")).toMatch(/^\d+ Agent Harbor sessions? started elsewhere/);
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
  // The +N menu hangs from its chip, as the session strip's does.
  "agent-harbor-initiative-tabs-overflow-menu": initiativeTabsCheck(async (el) => {
    // The bar's own checks first: this play replaces the bar's for its stories.
    await initiativeTabsDrawn(el);
    await overflowMenuHangs(el, ".ah-initiative-tab-bar");
    // The menu placed is the +N menu, not the sessions-elsewhere one.
    expect(el.querySelector(".ah-initiative-tab-bar > .ah-overflow-menu")).toBeTruthy();
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

  // A playback story (src/frontend/stories/agent_harbor_playback.nim): the
  // host's playback bar under it, at the first frame, whose controls move
  // the playback and the story with it. The bar lives on the document's
  // body (fixed along the canvas's bottom), not inside the story's root.
  // The suggested-actions block (CTF-P2c step 3): every story of it.
  "agent-harbor-suggested-actions-one": suggestedCheck(async (panel, block) => {
    expect(suggestedRows(panel).map((r) => [r.text, r.checked])).toEqual([
      ["Open the recording of drained_field_fails in a new tab, at pass 5", true]]);
    const approve = block.querySelector('[data-ah-suggested-button="approve"]');
    expect(approve.textContent).toBe("Approve");
    expect(approve.disabled).toBe(false);
    expect(approve.getAttribute("data-ct-operation")).toBe("suggested-actions.approve");
    expect(block.querySelector('[data-ah-suggested-button="dismiss"]')?.getAttribute("data-ct-operation"))
      .toBe("suggested-actions.dismiss");
    // Unchecking the only action disables Approve and says why.
    panel.querySelector('.ah-suggested-row[data-ah-target="open-recording"]').click();
    await waitUntil(() => suggestedBlock(panel)?.getAttribute("data-ah-approve-disabled") === "Choose an action to approve",
      "Approve disabled with its reason");
    expect(suggestedBlock(panel).querySelector('[data-ah-suggested-button="approve"]').disabled).toBe(true);
    panel.querySelector('.ah-suggested-row[data-ah-target="open-recording"]').click();
    await waitUntil(() => suggestedBlock(panel)?.getAttribute("data-ah-approve-disabled") === "", "Approve again");
    expect(recordLines(panel)).toEqual([]);
  }),
  "agent-harbor-suggested-actions-several": suggestedCheck(async (panel, block) => {
    expect(suggestedRows(panel).map((r) => r.checked)).toEqual([true, true, true]);
    expect(block.getAttribute("data-ah-approve-label")).toBe("Approve");
    await toggleRoundTrip(panel, "show-calltrace", "Approve 2 of 3");
  }),
  "agent-harbor-suggested-actions-partial": suggestedCheck(async (panel, block) => {
    const rows = suggestedRows(panel);
    expect(rows.map((r) => [r.checked, r.dimmed])).toEqual([[true, false], [false, true], [true, false]]);
    expect(block.getAttribute("data-ah-approve-label")).toBe("Approve 2 of 3");
    // The unchecked row's words are dimmer than a checked row's.
    const ink = (id) => getComputedStyle(panel.querySelector(`.ah-suggested-row[data-ah-target="${id}"] .ah-suggested-words`)).color;
    expect(ink("show-calltrace")).not.toBe(ink("open-recording"));
  }),
  "agent-harbor-suggested-actions-unsupported": suggestedCheck(async (panel, block) => {
    const rows = suggestedRows(panel);
    expect(rows.map((r) => [r.checked, r.disabled])).toEqual([[true, false], [true, false], [false, true]]);
    expect(rows[2].reason).toBe("No recording of drained_field_fails on macos-arm64 has been uploaded");
    expect(block.getAttribute("data-ah-approve-label")).toBe("Approve");
    // A press on the disabled row changes nothing: it carries no operation.
    panel.querySelector('.ah-suggested-row[data-ah-suggested-action="open-mac-recording"]').click();
    expect(suggestedRows(panel)[2].checked).toBe(false);
  }),
  "agent-harbor-suggested-actions-approved": suggestedCheck(async (panel, block) => {
    expect(block).toBeNull();
    expect(recordLines(panel)).toEqual([
      { text: "Approved 2 UI actions", level: 0, role: "body" },
      { text: "Opened the recording of drained_field_fails in a new tab, at pass 5", level: 1, role: "body" },
      { text: "Showed the call trace beside the editor", level: 1, role: "body" },
    ]);
  }),
  "agent-harbor-suggested-actions-dismissed": suggestedCheck(async (panel, block) => {
    expect(block).toBeNull();
    expect(recordLines(panel)).toEqual([{ text: "Dismissed 2 suggested UI actions", level: 0, role: "quiet" }]);
  }),
  "agent-harbor-suggested-actions-auto-approved": suggestedCheck(async (panel, block) => {
    expect(block).toBeNull();
    expect(recordLines(panel)).toEqual([
      { text: "Ran 1 UI action auto-approved", level: 0, role: "body" },
      { text: "Showed the Variables panel", level: 1, role: "body" },
    ]);
    const tag = [...panel.querySelectorAll('[data-ah-item-kind="ui-action"] .ah-activity-role-quiet')].map((e) => e.textContent);
    expect(tag).toEqual(["auto-approved"]);
  }),
  // The session activity timeline (CTF-P2b): every story of it.
  "agent-harbor-session-activity": async ({ canvasElement }) => {
    const panel = await activityChecks(canvasElement);
    if (panel.querySelector('[data-ah-focused="true"]')) await activityReader(panel);
  },
  // The comparison story: both halves show one session's one event list
  // (`againstCardsProblems`, written on the row by the mount), the
  // timeline is cardless, and the cards half is today's Agent Activity panel.
  "agent-harbor-session-activity-against-cards": async ({ canvasElement }) => {
    const row = await waitFor(canvasElement, ".ah-against-cards");
    expect(row.getAttribute("data-ah-against-problems")).toBe("");
    expect(row.getAttribute("data-ah-timeline-session")).toBe(row.getAttribute("data-ah-cards-session"));
    expect(Number(row.getAttribute("data-ah-timeline-events"))).toBeGreaterThan(0);
    expect(row.getAttribute("data-ah-timeline-events")).toBe(row.getAttribute("data-ah-cards-events"));
    await activityChecks(row.querySelector(".ah-against-timeline"));
    expect(row.querySelector(".ah-against-card-feed .agent-msg-wrapper")).toBeTruthy();
    // The cards half says the cards are today's pane, which mis-draws these
    // events, so the mis-rendering is not read as the timeline's.
    expect(row.querySelector(".ah-against-card-feed > .ah-against-caption")?.textContent)
      .toMatch(/^Today's Agent Activity cards, including a known mis-rendering/);
  },
  // The Changes panel (CTF-P3): every story's rows cardless; a story of its
  // spec cards draws at least one.
  "agent-harbor-changes": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, changesPanel);
    expect(codeMarkProblems(panel)).toEqual([]);
  },
  // The Changes panel's keys, pressed (step 3d; the listener had no test):
  // Down and Up move the keyboard's card, Enter closes and opens it, Right
  // and Left step the tabs. Each press is answered by its inverse, so the
  // story ends as it began (the captures shoot it as the play leaves it).
  "agent-harbor-changes-keys": async (context) => {
    await plays["agent-harbor-changes-cards"](context);
    const panel = context.canvasElement.querySelector(changesPanel);
    const focused = () => panel.querySelector(".ah-card-focused")?.getAttribute("data-ah-card") ?? "";
    const openCards = () => [...panel.querySelectorAll(".ah-card-open")].map((c) => c.getAttribute("data-ah-card"));
    const activeTab = () => panel.querySelector(".ah-changes-tab-active")?.textContent ?? "";
    const start = { focused: focused(), open: openCards(), tab: activeTab() };
    expect(start.focused).not.toBe("");
    expect(await pressKey(panel, "ArrowDown")).toBe(true);
    expect(focused()).not.toBe(start.focused);
    expect(await pressKey(panel, "ArrowUp")).toBe(true);
    expect(focused()).toBe(start.focused);
    expect(await pressKey(panel, "Enter")).toBe(true);
    expect(openCards()).not.toEqual(start.open);
    expect(await pressKey(panel, "Enter")).toBe(true);
    expect(openCards()).toEqual(start.open);
    expect(await pressKey(panel, "ArrowRight")).toBe(true);
    expect(activeTab()).not.toBe(start.tab);
    expect(await pressKey(panel, "ArrowLeft")).toBe(true);
    expect(activeTab()).toBe(start.tab);
    // A tab step leaves the keyboard on no card; Down twice puts it back on
    // the second, as the story's constructor did.
    await pressKey(panel, "ArrowDown");
    await pressKey(panel, "ArrowDown");
    expect({ focused: focused(), open: openCards(), tab: activeTab() }).toEqual(start);
  },
  // Far down 300 files (step 3d): the first frame shows the keyboard's
  // file, its list scrolled to it. (No key is pressed here: at the sidebar
  // width each redraw of the 300 rows takes tens of seconds on this tree;
  // the listener's keeping in view after a key is pressed on the long
  // inbox, below.)
  "agent-harbor-changes-keys-scroll": async (context) => {
    await plays["agent-harbor-changes"](context);
    await twoFrames();
    const panel = context.canvasElement.querySelector(changesPanel);
    const file = panel.querySelector(".ah-code-file-focused");
    expect(file).toBeTruthy();
    const region = scrollerOf(file);
    expect(region).toBeTruthy();
    expect(region.scrollTop).toBeGreaterThan(0);
    expect(inRegionView(file)).toBe(true);
  },
  // Far down the forty items (step 3d): the first frame shows the item on
  // screen, its rows scrolled to it; after `]` (the top of the inbox) and
  // `[` (back to it) the listener keeps each in view. The story ends as it
  // began: the same item, the rows scrolled back as they were.
  "agent-harbor-inbox-keys-scroll": async (context) => {
    await plays["agent-harbor-inbox-rows"](context);
    await twoFrames();
    const panel = context.canvasElement.querySelector(inboxPanel);
    const current = () => panel.querySelector(".ah-inbox-row-current");
    const at = current()?.getAttribute("data-ah-item");
    expect(at).toBeTruthy();
    const region = scrollerOf(current());
    expect(region).toBeTruthy();
    const top = region.scrollTop;
    expect(top).toBeGreaterThan(0);
    expect(inRegionView(current())).toBe(true);
    try {
      expect(await pressKey(panel, "]", "BracketRight")).toBe(true);
      expect(current()?.getAttribute("data-ah-item")).not.toBe(at);
      expect(inRegionView(current())).toBe(true);
      expect(await pressKey(panel, "[", "BracketLeft")).toBe(true);
      expect(current()?.getAttribute("data-ah-item")).toBe(at);
      expect(inRegionView(current())).toBe(true);
    } finally {
      region.scrollTop = top;
    }
  },
  "agent-harbor-changes-cards": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, changesPanel, { rows: true });
    expect(panel.querySelectorAll(".ah-spec-card").length).toBeGreaterThan(0);
  },
  // The Inbox panel: every story's rows and page cardless; a story of its
  // rows draws at least one, the item on screen as the one selected row.
  "agent-harbor-inbox": async ({ canvasElement }) => {
    await changesInboxChecks(canvasElement, inboxPanel);
  },
  "agent-harbor-inbox-rows": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, inboxPanel, { rows: true });
    expect(panel.querySelectorAll(".ah-inbox-row").length).toBeGreaterThan(0);
    expect(panel.querySelectorAll(".ah-inbox-row-current").length).toBeLessThanOrEqual(1);
    expect(inboxHintProblems(panel)).toEqual([]);
    expect(itemPageProblems(panel)).toEqual([]);
  },
  // Mid-walk (`prev-next`): `3 of 5` with both steps enabled, the row on
  // screen selected; the first step of a walk (`1 of 5`) cannot go back;
  // the last of the order (`5 of 5`), reached by going back from the top
  // to the only item visited, cannot go back either and still goes on while
  // items wait.
  // Mid-walk, the keys are pressed too (step 3d; the listener had no
  // test): `]` steps to the top of the inbox and `[` back to the item it
  // left, so the story ends as it began; `]` typed in the page's text field
  // is the field's, never Next.
  "agent-harbor-inbox-prev-next": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, inboxPanel, { rows: true });
    stepperIs(panel, "3 of 5", { prev: true, next: true });
    const position = () => panel.querySelector(".ah-inbox-stepper")?.getAttribute("data-ah-position");
    expect(await pressKey(panel, "]", "BracketRight")).toBe(true);
    expect(position()).not.toBe("3 of 5");
    expect(await pressKey(panel, "[", "BracketLeft")).toBe(true);
    stepperIs(panel, "3 of 5", { prev: true, next: true });
    const field = panel.querySelector(".ah-item-page textarea, .ah-item-page input[type=password]");
    expect(field).toBeTruthy();
    expect(await pressKey(field, "]", "BracketRight")).toBe(false);
    expect(await pressKey(field, "1", "Digit1")).toBe(false);
    stepperIs(panel, "3 of 5", { prev: true, next: true });
  },
  "agent-harbor-inbox-prev-next-first": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, inboxPanel, { rows: true });
    stepperIs(panel, "1 of 5", { prev: false, next: true });
  },
  "agent-harbor-inbox-prev-next-end": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, inboxPanel, { rows: true });
    stepperIs(panel, "5 of 5", { prev: false, next: true });
    // Its page holds a manager's draft: `Send draft` compact, as `Submit`.
    expect(itemPageProblems(panel)).toEqual([]);
  },
  // An empty inbox: the notice, no row, both steps disabled.
  "agent-harbor-inbox-empty": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, inboxPanel);
    expect(panel.querySelectorAll(".ah-inbox-row").length).toBe(0);
    const stepper = panel.querySelector(".ah-inbox-stepper");
    expect(stepper.querySelector(".ah-step-prev").disabled).toBe(true);
    expect(stepper.querySelector(".ah-step-next").disabled).toBe(true);
  },
  // An item's page on its own (`agent-harbor-inbox-item`): cardless.
  "agent-harbor-inbox-item": async ({ canvasElement }) => {
    const panel = await changesInboxChecks(canvasElement, inboxItemPanel);
    expect(panel.querySelectorAll(".ah-item-page, .ah-item-head").length).toBeGreaterThan(0);
    expect(itemPageProblems(panel)).toEqual([]);
  },
  // A single choice and the priority dropdown, pressed: their presses are
  // routed (each element carries its operation, `data-ct-operation`, and
  // the page's one pointer listener runs the procedure bound to it), so a
  // press that reached no procedure leaves the drawing as it was. The
  // trigger opens its menu of design-system rows and closes it again; a
  // toggle chooses its option and the first one is chosen back. The story
  // ends as it began (the captures shoot it as the play leaves it).
  "agent-harbor-inbox-item-presses": async (context) => {
    await plays["agent-harbor-inbox-item"](context);
    const panel = context.canvasElement.querySelector(inboxItemPanel);
    const trigger = panel.querySelector(".ah-item-head .ah-dropdown-trigger");
    expect(trigger).toBeTruthy();
    expect(trigger.getAttribute("data-ct-operation")).toBe("dropdown.toggle");
    const rows = () => [...panel.querySelectorAll(".ah-item-head .ah-dropdown-item")];
    expect(rows().length).toBe(0);
    trigger.click();
    await twoFrames();
    expect(trigger.getAttribute("aria-expanded")).toBe("true");
    expect(rows().length).toBe(4);
    for (const row of rows()) {
      expect(row.classList.contains("ct-menu-item")).toBe(true);
      expect(row.getAttribute("data-ct-operation")).toBe("dropdown.choose");
    }
    trigger.click();
    await twoFrames();
    expect(trigger.getAttribute("aria-expanded")).toBe("false");
    expect(rows().length).toBe(0);
    const toggles = () => [...panel.querySelectorAll(".ah-choices-single .ah-choice")];
    const chosen = () => toggles().filter((t) => t.getAttribute("aria-checked") === "true")
      .map((t) => t.getAttribute("data-ah-choice"));
    expect(toggles().length).toBeGreaterThan(1);
    for (const t of toggles()) expect(t.getAttribute("data-ct-operation")).toBe("inbox.choose-option");
    const before = chosen();
    const first = toggles()[0].getAttribute("data-ah-choice");
    const other = toggles().find((t) => !before.includes(t.getAttribute("data-ah-choice")) &&
                                       t.getAttribute("data-ah-choice") !== first);
    expect(other).toBeTruthy();
    const otherId = other.getAttribute("data-ah-choice");
    other.click();
    await twoFrames();
    expect(chosen()).toEqual([otherId]);
    // Back as the story began: its constructor's choice, or none.
    const back = before.length > 0 ? before[0] : otherId;
    panel.querySelector(`.ah-choices-single .ah-choice[data-ah-choice="${back}"]`).click();
    await twoFrames();
    expect(chosen()).toEqual(before);
  },
  // The inbox's playback: the playback bar's check, then the inbox's own.
  "agent-harbor-inbox-playback": async (context) => {
    await plays["agent-harbor-playback"](context);
    await plays["agent-harbor-inbox-rows"](context);
  },
  // A playback story of the timeline: the playback bar's check, then the
  // timeline's own.
  "agent-harbor-session-activity-playback": async (context) => {
    await plays["agent-harbor-playback"](context);
    await activityChecks(context.canvasElement);
  },
  "agent-harbor-playback": async () => {
    const bar = await waitFor(document, ".ah-playback");
    // Each button's accessible name is its word, whichever of its word and
    // its glyph the bar's width shows (`.ah-playback-glyph` under 720px).
    const buttons = [...bar.querySelectorAll(".ah-playback-button")].map((b) => b.getAttribute("aria-label"));
    expect(buttons).toEqual(["Play", "Step", "\u25c0 Moment", "Moment \u25b6", "Rewind"]);
    const shown = [...bar.querySelectorAll(".ah-playback-button")].map((b) =>
      [...b.children].filter((c) => getComputedStyle(c).display !== "none").map((c) => c.textContent).join(""));
    expect(shown).toEqual(window.innerWidth < 720
      ? ["\u25b6", "\u203a", "\u00ab", "\u00bb", "\u21ba"]
      : ["Play", "Step", "\u25c0 Moment", "Moment \u25b6", "Rewind"]);
    const moment = () => document.querySelector(".ah-playback .ah-playback-moment")?.textContent;
    const time = () => document.querySelector(".ah-playback .ah-playback-time")?.textContent;
    const opened = new URLSearchParams(window.location.search).get("globals") ?? "";
    if (!opened.includes("moment:")) {
      expect(moment()).toBe("first frame");
      expect(time()).toBe("+0:00");
    }
    // The next named moment, then back: a seek backwards rebuilds from the
    // first frame, so the readout returns to where it was. A story opened at
    // a named moment goes the other way round, back and then forward again:
    // the scenario's last moment has no next one, and every moment has one
    // before it (the first frame, before the first). Either way the story is
    // left where it was opened, which the moment captures rely on.
    const before = moment();
    const [away, back] = opened.includes("moment:")
      ? [".ah-playback-previous", ".ah-playback-next"]
      : [".ah-playback-next", ".ah-playback-previous"];
    document.querySelector(away).click();
    await waitUntil(() => moment() !== before, "the moment " + (opened.includes("moment:") ? "before" : "after") + " " + before);
    expect(moment()).not.toBe("between moments");
    document.querySelector(back).click();
    await waitUntil(() => moment() === before, "the seek back to " + before);
  },

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
  // A whole-window layout whose editor replays one of the failing tests'
  // recordings: those were made of `src/shield.nr` before the agent's clamp,
  // so the editor shows that revision (`calculate_damage` ending in the bare
  // `damage` at line 34, no clamp anywhere), never the reviewed one the Deep
  // Review shows. Read from the editor's own model, so a layout wired to the
  // program's current source fails here.
  // L3 (CTF-P2c step 3): the drained-field session as its timeline, the
  // agent's suggestion in the block at its end, and no permission card.
  "layout-l3-suggested-actions": async (context) => {
    await plays["layout-editor-before-clamp"](context);
    const { canvasElement } = context;
    const block = await waitFor(canvasElement, '.ah-suggested[data-ah-suggested="block"]', 30000);
    expect(block.getAttribute("data-ah-suggestion-phase")).toBe("pending");
    expect([...block.querySelectorAll(".ah-suggested-words")].map((w) => w.textContent))
      .toEqual(["Open the recording of drained_field_fails in a new tab, at pass 5"]);
    expect(block.closest(".agent-harbor-activity")).toBeTruthy();
    // The stand-in, the Agent Activity pane's permission prompt, is gone.
    expect(canvasElement.querySelector(".permission-prompt")).toBeNull();
  },
  "layout-editor-before-clamp": async ({ canvasElement }) => {
    await waitFor(canvasElement, ".monaco-editor .view-line", 60000);
    const host = canvasElement.querySelector(".monaco-editor").parentElement;
    const model = host.__ctStoryMonaco?.getModel();
    await expect(model).toBeTruthy();
    await expect(model.getLineContent(34).trim()).toBe("damage");
    await expect(model.getValue()).not.toContain("if(damage as u32 > remaining_shield as u32)");
  },
};
