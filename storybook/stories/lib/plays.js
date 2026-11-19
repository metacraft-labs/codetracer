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
// with its progress and its state class, and exactly one active.
async function initiativeTabsDrawn(el) {
  await waitFor(el, ".ah-initiative-tab");
  expect(el.querySelectorAll(".ah-initiative-tab").length).toBeGreaterThan(0);
  for (const tab of el.querySelectorAll(".ah-initiative-tab")) {
    expect(tab.querySelector(".ah-tab-progress")?.textContent).toMatch(/^\d+\/\d+$/);
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

const composerCheck = (assert) => hostCheck(".ah-composer-sheet", assert);
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

export const plays = {
  ...composerChecks,
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
  "layout-editor-before-clamp": async ({ canvasElement }) => {
    await waitFor(canvasElement, ".monaco-editor .view-line", 60000);
    const host = canvasElement.querySelector(".monaco-editor").parentElement;
    const model = host.__ctStoryMonaco?.getModel();
    await expect(model).toBeTruthy();
    await expect(model.getLineContent(34).trim()).toBe("damage");
    await expect(model.getValue()).not.toContain("if(damage as u32 > remaining_shield as u32)");
  },
};
