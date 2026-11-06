// When a CodeTracer story has rendered, and whether what it rendered is a
// story: the one definition both the render check
// (`storybook/scripts/check-story-render.mjs`, `just storybook-check-render`)
// and the capture tool (`tools/visual-review/capture-storybook.mjs`) use.
//
// Shared, not copied, because the two answer the same question at different
// times. The capture tool used to decide for itself that a story had
// rendered (visible text in `#storybook-root`, then 750 ms), and shot panels
// whose data had not arrived yet while the render check, waiting longer,
// passed the same stories. A capture is now taken only after the render
// check's readiness, and only of a story the render check's judge passes.
//
// The module drives a Playwright page it is given; it imports nothing from
// Playwright itself, so each caller resolves its own installation.
//
// The verdict's categories:
//
//   placeholder  The story shows a placeholder instead of its surface: the
//                harness's "No structure story registered for <surface>"
//                (`mountStructure`'s fallback in
//                src/frontend/storybook_components.nim), or, in a story
//                whose declaration says it shows data, a component's empty,
//                loading or error state, or nothing but lines worded as a
//                state message ("No calls recorded", "Loading initiatives…",
//                "Failed to load the call trace") whatever element draws them,
//                with at most an icon or a spinner beside them.
//   empty        The story's content area shows nothing beyond chrome: no
//                text and no image outside buttons, inputs, tabs, the
//                panel's own header, the panel's name wherever it is drawn,
//                and Monaco's own furniture (its gutter, line numbers,
//                overlays and scrollbars: an editor with an empty model is
//                empty). Content counts only where a person sees it: an
//                ancestor's `opacity`, `visibility` or `display` hides it.
//   error        The page logged a console error, threw (`pageerror`), a
//                request failed (aborted included: only the theme
//                stylesheet a theme switch supersedes is excused) or
//                answered >= 400, the story's play check
//                threw, or StoryBook never finished rendering it.
//   type-size    A panel (a GoldenLayout root) inherits another type size
//                than the window's: the app mounts every panel in `#ROOT`'s
//                session container, never in `#main` (1.25rem).
//
// What a story is meant to show comes from its declaration
// (`src/frontend/stories/codetracer_stories.nim`, `state`, emitted into
// `storybook/stories/generated/stories.json`): `data` (the default) or a
// declared `empty`, `loading` or `error` state. A story that declares a state
// must show that state -- the marker is verified, so it cannot be used to
// silence the check -- and a story that declares data must show no such
// state. There is no allowlist.

import { readFileSync } from "node:fs";
import { join } from "node:path";

// --- What counts as a state, and as chrome ------------------------------------

// A declared state and the visible evidence of it. The class vocabulary is
// CodeTracer's own: the shared empty-state treatment (`empty-overlay`,
// `components/empty_states.styl`), the per-panel `<panel>-empty` /
// `<panel>-loading` / `<panel>-error-overlay` classes the views emit, and the
// harness's missing-story marker. A class token is a state marker when it
// ENDS in the state word (optionally followed by overlay/state/message/text),
// so `build-line-error` (an error line of build output: data) and
// `rr-ticks-empty-remaining` (a gauge segment) are not.
export const STATE_PATTERNS = {
  empty: /(^|-)empty(-(overlay|state|message|text|prompt))?$/,
  loading: /(^|-)loading(-(overlay|state|message|text|indicator))?$|^loading-indicator$/,
  error: /(^|-)error-(overlay|message|state)$/,
};
// Leaf text that reads as a state, for the declared-state verification: a
// view may draw its state without a class.
export const STATE_TEXT = {
  empty: /^(No |Nothing |Select an? )/,
  loading: /^Loading\b/,
  error: /^(Error|Failed|Could not)\b|\b(did not answer|could not be reached|connection refused)\b/,
};
// The wording of a state message as a whole line of text, per state. In a
// story that declares data, a story (or a layout panel) that shows nothing but
// such lines shows that state, whatever element draws them and whatever
// classes it carries. Empty: "No calls recorded", "Nothing to show", "There
// are no sessions" -- capitalised, so a value that is data ("no initiative")
// is not one. Loading: "Loading…", "Loading initiatives…". Error: "Error: …",
// "Failed to …", "Could not load the sessions", "… did not answer".
export const MESSAGE_WORDING = {
  empty: /^(No|Nothing) [a-z]|^There (is|are) (no|nothing)\b/,
  loading: STATE_TEXT.loading,
  error: STATE_TEXT.error,
};
export const MISSING_TEXT = "No structure story registered";
export const MISSING_CLASS = "ct-storybook-missing";
// Elements whose text is chrome rather than content: controls, tabs and the
// golden-layout header the harness draws around a panel.
export const CHROME = "button,[role=button],input,select,textarea,label,[role=tab],[role=toolbar],.lm_header";
// The stylesheet `setCodeTracerTheme` swaps (`frontend/styles/<name>_theme_electron.css`).
export const THEME_STYLESHEET = /\/[a-z_]+_theme_electron\.css$/;
// StoryBook's preview announces the end of a render (after the play check)
// and every failure on its channel.
export const STORYBOOK_EVENTS = ["storyRendered", "storyErrored", "storyThrewException", "playFunctionThrewException", "storyMissing"];

// The story declarations (`just storybook-stories` writes them from
// codetracer_stories.nim): `{ stories: [{ id, name, kind, state, ... }] }`.
export function loadStoryDeclarations(repoRoot) {
  return JSON.parse(readFileSync(join(repoRoot, "storybook", "stories", "generated", "stories.json"), "utf8"));
}

export function storyUrl(baseUrl, storyId, theme) {
  return `${baseUrl.replace(/\/$/, "")}/iframe.html?id=${storyId}&viewMode=story&globals=theme:${theme}`;
}

// --- In the page: what the story drew ----------------------------------------

function inspectStory({ statePatterns, stateText, messageWording, missingText, missingClass, chrome, storyTitles }) {
  const revive = (map) => Object.fromEntries(Object.entries(map).map(([k, [src, flags]]) => [k, new RegExp(src, flags)]));
  const patterns = revive(statePatterns);
  const texts = revive(stateText);
  const wording = revive(messageWording);
  // Seen by a person: a box with an area, not hidden, and not faded out by
  // itself OR BY AN ANCESTOR. `opacity` does not inherit (a child of an
  // `opacity: 0` box computes 1), so the effective opacity is the product
  // along the chain; `display: none` on an ancestor gives no box, which the
  // area test catches, and `visibility` inherits, so the element's own value
  // is the chain's.
  const opacityOf = new Map();
  const effectiveOpacity = (el) => {
    if (!el || el.nodeType !== Node.ELEMENT_NODE) return 1;
    if (opacityOf.has(el)) return opacityOf.get(el);
    const style = getComputedStyle(el);
    const own = style.display === "none" ? 0 : Number(style.opacity);
    const value = own * effectiveOpacity(el.parentElement);
    opacityOf.set(el, value);
    return value;
  };
  const visible = (el) => {
    const box = el.getBoundingClientRect();
    if (box.width < 1 || box.height < 1) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none" && effectiveOpacity(el) > 0.05;
  };
  // Monaco's own furniture is chrome: the gutter (line numbers, folding and
  // glyph margins), the overlays (current-line and selection highlights),
  // the rulers, the scrollbars and the minimap. An editor whose model is
  // empty still draws the number "1" and its margin marks, and is still an
  // empty editor. What it shows of the document is content: the text lines
  // (`.view-lines`, a diff's deleted lines among them), the view zones and
  // the content widgets (the review's value bands are both).
  const MONACO_CONTENT = ".view-lines, .view-zones, .contentWidgets, .overflowingContentWidgets";
  const isMonacoChrome = (el) => !!el.closest(".monaco-editor") && !el.closest(MONACO_CONTENT);
  const isChrome = (el) => !!el.closest(chrome) || isMonacoChrome(el);
  const root = document.querySelector("#storybook-root");
  if (!root) return { missingRoot: true };
  const surface = root.querySelector(".ct-storybook-surface");
  const kind = surface?.dataset.kind ?? "";
  // The content area: inside a panel's frame, below its header; a layout's
  // whole window (its panels are judged one by one below); otherwise the
  // whole story frame.
  const content = kind === "layout" ? root
    : root.querySelector(".ct-storybook-panel-content") ?? root.querySelector(".ct-storybook-frame") ?? root;

  // A panel's name is chrome wherever it is drawn: the golden-layout tab,
  // and a panel's own title bar repeating it (a Calltrace panel reduced to a
  // bar reading "Calltrace" shows nothing). The names are the stack tabs'
  // titles and the story's own declared names, compared without case,
  // spacing or punctuation.
  const norm = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g, "");
  const titles = new Set(storyTitles.map(norm).filter(Boolean));
  for (const t of root.querySelectorAll(".lm_title")) if (norm(t.textContent)) titles.add(norm(t.textContent));
  const isTitle = (text) => titles.has(norm(text));

  // A line worded as a state message (`messageWording`: "No calls recorded",
  // "Loading initiatives…", "Failed to load …"), whatever element draws it: a
  // view can say so in a plain `<div>`, with none of the state classes below.
  // Only a whole short line of content counts (not chrome, not the editor's
  // document), and only a state's wording, so "No" or "failed" inside a
  // sentence of data does not. The line is the element whose WHOLE text is
  // worded so: a leaf, or a small element whose words are split over inline
  // children ("Loading <span>the call trace</span>…"), so a text inside such
  // a line belongs to it. Such a line is set apart from the content: a story
  // that declares data and shows nothing BUT such lines (and the icon or
  // spinner drawn beside them, see `judge`) shows that state. A line like it
  // beside real data ("No pixel selected" under a frame list, "No initiative"
  // heading a group of sessions) is part of that data.
  const lineOf = (el) => el.textContent.trim().replace(/\s+/g, " ");
  // At most this many elements inside a message line: its inline pieces and
  // an icon, never a list or a row of data.
  const MESSAGE_MAX_DESCENDANTS = 6;
  const wordedStateOf = (el) => {
    if (isChrome(el) || el.closest(".monaco-editor") || el.querySelector(chrome)) return null;
    if (el.querySelectorAll("*").length > MESSAGE_MAX_DESCENDANTS) return null;
    const text = lineOf(el);
    if (!text || text.length > 120) return null;
    for (const [state, re] of Object.entries(wording)) if (re.test(text)) return state;
    return null;
  };
  // The message line `el` is part of: `el` itself or the nearest of its
  // ancestors (a few levels, inside the content area) whose whole text is
  // worded as a state message. Null when it is part of no such line.
  const messageLineOf = (el) => {
    for (let a = el, depth = 0; a && a !== content && depth < 4; a = a.parentElement, depth++) {
      const state = wordedStateOf(a);
      if (state) return { state, el: a };
      if (lineOf(a).length > 120) return null;
    }
    return null;
  };
  const messageStateOf = (el) => messageLineOf(el)?.state ?? null;
  // Media of at most this size are an icon, a status mark or a spinner: beside
  // a state message they are part of it, not content of their own.
  const SMALL_MEDIUM = 32;
  const isSmallMedium = (el) => {
    const box = el.getBoundingClientRect();
    return box.width <= SMALL_MEDIUM && box.height <= SMALL_MEDIUM;
  };

  let contentText = "";
  let chromeText = "";
  const messageTexts = [];
  const messageLines = new Set();
  const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const text = node.textContent.trim();
    const parent = node.parentElement;
    if (!text || !parent || !visible(parent)) continue;
    if (isChrome(parent) || isTitle(text) || isTitle(parent.textContent)) {
      chromeText += text + " ";
      continue;
    }
    const line = messageLineOf(parent);
    if (line) {
      // One entry per line, however many text nodes it is split into.
      if (!messageLines.has(line.el)) messageTexts.push({ state: line.state, text: lineOf(line.el) });
      messageLines.add(line.el);
    } else contentText += text + " ";
  }
  // Inputs show their value as content: a recalled command is data. A
  // placeholder hint is chrome (the caption bar's omnibox field).
  for (const input of content.querySelectorAll("input,textarea")) {
    if (!visible(input)) continue;
    if (input.value.trim()) contentText += input.value.trim() + " ";
    else if (input.placeholder?.trim()) chromeText += input.placeholder.trim() + " ";
  }
  const media = [...content.querySelectorAll("img,svg,canvas,video")].filter((m) => {
    const box = m.getBoundingClientRect();
    return visible(m) && box.width >= 8 && box.height >= 8;
  });
  // Marks drawn by CSS count as images: a status dot, a rail of them (a
  // collapsed session list is nothing else). A mark is a childless, textless
  // box of at most 32px that paints a background or a border.
  for (const el of content.querySelectorAll("*")) {
    if (el.childElementCount !== 0 || el.textContent.trim() || !visible(el)) continue;
    const box = el.getBoundingClientRect();
    if (box.width < 4 || box.height < 4 || box.width > 32 || box.height > 32) continue;
    const style = getComputedStyle(el);
    const paints = !/rgba\(0, 0, 0, 0\)|transparent/.test(style.backgroundColor) ||
      (parseFloat(style.borderTopWidth) > 0 && !/rgba\(0, 0, 0, 0\)|transparent/.test(style.borderTopColor));
    if (paints) media.push(el);
  }
  const contentMedia = media.filter((m) => !isChrome(m)).length;
  // The media larger than an icon: what still counts as content beside a
  // state message (`judge`).
  const contentLargeMedia = media.filter((m) => !isChrome(m) && !isSmallMedium(m)).length;
  const chromeLargeMedia = media.filter((m) => isChrome(m) && !isSmallMedium(m)).length;

  const states = [];
  for (const el of content.querySelectorAll("*")) {
    if (!visible(el)) continue;
    const text = (el.textContent ?? "").trim().replace(/\s+/g, " ");
    if (el.classList.contains(missingClass) || (el.childElementCount === 0 && text.startsWith(missingText))) {
      states.push({ state: "missing", cls: el.className.toString(), text: text.slice(0, 120) });
      continue;
    }
    // A state is a message: not a control (a filter chip with no match is
    // `…-filter-empty`, and still a filter), not a container that holds
    // the panel (a list body's `…-no-initiative` modifier), and not Monaco's
    // own markup: its class names are the editor's (a diff's empty deleted
    // range is `.diff-range-empty`), not CodeTracer's state vocabulary.
    if (el.closest(chrome) || el.closest(".monaco-editor") || el.querySelectorAll("*").length > 4) continue;
    for (const [state, pattern] of Object.entries(patterns)) {
      if ([...el.classList].some((c) => pattern.test(c))) {
        states.push({ state, cls: el.className.toString().slice(0, 80), text: text.slice(0, 120) });
      }
    }
    // A "no X" message of its own (`vcs-no-files`, `menu-no-search-results`):
    // the class says "no", the text says so as a sentence. A lower-case value
    // that is data ("no initiative", `ah-elsewhere-no-initiative`) is not one.
    if ([...el.classList].some((c) => /(^|-)no-[a-z]+/.test(c)) && texts.empty.test(text)) {
      states.push({ state: "empty", cls: el.className.toString().slice(0, 80), text: text.slice(0, 120) });
    }
  }
  // Leaf text that reads as a state ("No sessions", "Loading ..."), for the
  // declared-state verification: a view may draw its state without a class.
  const stateTexts = [];
  for (const el of content.querySelectorAll("*")) {
    if (el.childElementCount !== 0 || !visible(el) || el.closest(".monaco-editor")) continue;
    const text = el.textContent.trim();
    for (const [state, pattern] of Object.entries(texts)) {
      if (pattern.test(text)) stateTexts.push({ state, text: text.slice(0, 120) });
    }
  }
  // The type size panels are drawn at. In the app every GoldenLayout root
  // inherits the window's (`html`) size through `#ROOT` and the session
  // container: `#main` and its 1.25rem hold no panel (`index.html`,
  // `ui/layout.initLayout`). A story that mounts its panels anywhere else
  // draws every pane's text at another size than the app's.
  const rootFontSize = getComputedStyle(document.documentElement).fontSize;
  const typeSizes = [];
  for (const layout of root.querySelectorAll(".lm_goldenlayout")) {
    if (!visible(layout)) continue;
    const size = getComputedStyle(layout).fontSize;
    if (size !== rootFontSize) {
      typeSizes.push({
        size,
        rootSize: rootFontSize,
        panel: layout.querySelector(".lm_tab.lm_active .lm_title")?.textContent ?? "a panel",
      });
    }
  }
  // Where the content is drawn, in page coordinates (a full-page screenshot's
  // pixels at device scale 1): the content area, and a layout's every shown
  // panel. A capture records them so its image can be checked for having
  // drawn something there (tools/visual-review/check-storybook-captures.mjs).
  // A view's or a component's frame can have no height of its own (a strip
  // laid out by its children), so a box too small to hold anything is
  // replaced by the union of what is visible inside it.
  const pageBox = (el, name) => {
    let b = el.getBoundingClientRect();
    let { left, top, right, bottom } = b;
    if (b.width < 8 || b.height < 8) {
      left = top = Infinity;
      right = bottom = -Infinity;
      for (const d of el.querySelectorAll("*")) {
        if (!visible(d)) continue;
        const r = d.getBoundingClientRect();
        left = Math.min(left, r.left); top = Math.min(top, r.top);
        right = Math.max(right, r.right); bottom = Math.max(bottom, r.bottom);
      }
      if (!Number.isFinite(left)) ({ left, top, right, bottom } = b);
    }
    return { name, x: Math.round(left + scrollX), y: Math.round(top + scrollY), width: Math.round(right - left), height: Math.round(bottom - top) };
  };
  const contentBoxes = [];
  // A layout's panels: each shown panel (the active tab of its stack) must
  // show something beyond its chrome, as a panel story must.
  const emptyPanels = [];
  const messagePanels = [];
  if (kind === "layout") {
    for (const panel of root.querySelectorAll(".ct-storybook-panel-content")) {
      if (!visible(panel)) continue;
      const stack = panel.closest(".lm_stack");
      const name = stack?.querySelector(".lm_tab.lm_active .lm_title")?.textContent ?? stack?.dataset.panelName ?? "a panel";
      contentBoxes.push(pageBox(panel, name));
      const messages = [];
      for (const el of panel.querySelectorAll("*")) {
        if (!visible(el)) continue;
        const state = messageStateOf(el);
        if (state) messages.push({ state, text: lineOf(el) });
      }
      // Shown: text that is not a state message, or an image. An icon or a
      // spinner beside a state message is part of the message.
      let smallMediumShown = false;
      const shown = [...panel.querySelectorAll("*")].some((el) => {
        if (!visible(el) || isChrome(el) || messageStateOf(el)) return false;
        if (/^(IMG|SVG|CANVAS|VIDEO|svg)$/.test(el.tagName)) {
          if (!isSmallMedium(el)) return true;
          smallMediumShown = true;
          return false;
        }
        if (isTitle(el.textContent)) return false;
        return [...el.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && n.textContent.trim().length > 0 && !isTitle(n.textContent));
      }) || (smallMediumShown && messages.length === 0);
      if (!shown) {
        if (messages.length) messagePanels.push({ name, state: messages[0].state, text: messages[0].text.slice(0, 120) });
        else emptyPanels.push(name);
      }
    }
  }
  // A layout drawn without the harness's panel frames (the standalone app
  // shell) is judged as one box, as a panel is.
  if (contentBoxes.length === 0) contentBoxes.push(pageBox(content, kind || "story"));
  const box = content.getBoundingClientRect();
  return {
    kind,
    emptyPanels,
    messagePanels,
    contentText: contentText.trim(),
    chromeText: chromeText.trim(),
    contentMedia,
    chromeMedia: media.length - contentMedia,
    contentLargeMedia,
    chromeLargeMedia,
    states,
    stateTexts,
    messageTexts,
    typeSizes,
    contentBox: { width: Math.round(box.width), height: Math.round(box.height) },
    contentBoxes,
  };
}

// --- The verdict ------------------------------------------------------------------

// The verdict for one rendered story: a list of failures, each with its
// category (`placeholder`, `empty`, `error`, `type-size`). An empty list is a
// pass.
export function judge(story, observed) {
  const failures = [];
  const add = (category, message) => failures.push({ category, message });
  for (const e of observed.errors) add("error", e);
  const page = observed.page;
  if (!page) {
    if (failures.length === 0) add("error", "the story was never inspected");
    return failures;
  }
  if (page.missingRoot) {
    add("error", "no #storybook-root in the story's page");
    return failures;
  }
  const declared = story.state ?? "data";
  const missing = page.states.filter((s) => s.state === "missing");
  for (const s of missing) add("placeholder", `renders the harness's placeholder: "${s.text}"`);
  const shown = page.states.filter((s) => s.state !== "missing");
  if (declared === "data") {
    for (const s of shown) add("placeholder", `declares data but shows a ${s.state} state (.${s.cls.split(" ").join(".")}: "${s.text}")`);
  } else {
    const evidence = shown.some((s) => s.state === declared) || page.stateTexts.some((s) => s.state === declared);
    if (!evidence) add("placeholder", `declares the ${declared} state but shows none (no ${declared} element or text)`);
  }
  // Empty: nothing beyond chrome. For a panel or a layout the chrome does
  // not count (a toolbar over nothing is an empty panel); for a view or a
  // component -- a strip, a tab bar, a menu -- the controls ARE the content.
  const chromeIsContent = page.kind === "view" || page.kind === "component";
  const messageTexts = page.messageTexts ?? [];
  // A declared empty, loading or error state's message is that story's
  // content; in a story that declares data it is not.
  const messageText = declared === "data" ? "" : messageTexts.map((m) => m.text).join(" ");
  const text = [page.contentText, chromeIsContent ? page.chromeText : "", messageText].join(" ").trim();
  const mediaCount = chromeIsContent ? page.contentMedia + page.chromeMedia : page.contentMedia;
  for (const panel of page.emptyPanels ?? []) {
    add("empty", `the layout's ${panel} panel shows nothing beyond chrome`);
  }
  const nothing = text.replace(/\s/g, "").length < 3 && mediaCount === 0 && missing.length === 0;
  const onlyMessage = declared === "data" && messageTexts.length > 0;
  // Beside a state message an icon, a status mark or a spinner (a medium of
  // at most SMALL_MEDIUM px) is part of the message: "Loading…" with a
  // spinner still shows nothing but the loading state.
  const largeMediaCount = chromeIsContent
    ? (page.contentLargeMedia ?? 0) + (page.chromeLargeMedia ?? 0)
    : (page.contentLargeMedia ?? 0);
  const nothingButMessages = onlyMessage && text.replace(/\s/g, "").length < 3 && largeMediaCount === 0 && missing.length === 0;
  if (declared === "data") {
    for (const panel of page.messagePanels ?? []) {
      add("placeholder", `declares data but the layout's ${panel.name} panel shows only a ${panel.state}-state message: "${panel.text}"`);
    }
    if (nothingButMessages) {
      const first = messageTexts[0];
      add("placeholder", `declares data but shows only a ${first.state}-state message: "${first.text.slice(0, 120)}"`);
    }
  }
  // (In a story that declares a state, a layout panel that shows only that
  // state's message shows the state: `messagePanels` is not empty.)
  if (nothing && !onlyMessage) {
    add("empty", `the ${page.kind || "story"}'s content area (${page.contentBox.width}x${page.contentBox.height}) shows nothing beyond chrome` +
      (page.chromeText ? ` (chrome: "${page.chromeText.slice(0, 60)}")` : ""));
  }
  for (const t of page.typeSizes ?? []) {
    add("type-size", `the ${t.panel} panel inherits ${t.size}, the window's type size is ${t.rootSize}` +
      " (mounted outside the app's #ROOT > .session-container chain)");
  }
  return failures;
}

// --- Driving a page --------------------------------------------------------------

// watchStoryPage(page) -> observed. Call BEFORE navigating: it records every
// console error, page error, failed request and >= 400 response into
// `observed.errors`, and captures StoryBook's channel as the preview creates
// it so no render event is missed.
export async function watchStoryPage(page) {
  const observed = { errors: [], page: null, abortedThemeLoads: [] };
  page.on("console", (message) => {
    if (message.type() === "error") observed.errors.push(`console error: ${message.text().slice(0, 300)}`);
  });
  page.on("pageerror", (error) => observed.errors.push(`page error: ${String(error).slice(0, 300)}`));
  page.on("requestfailed", (request) => {
    const reason = request.failure()?.errorText ?? "?";
    // Switching the theme replaces the `#theme` stylesheet's href
    // (`setCodeTracerTheme`, .storybook/appStyles.js), which aborts the
    // default theme's load while it is in flight. That one abort is the
    // page's own doing, verified once the story has rendered
    // (`settleStory`); any other aborted request (a script, a fixture, an
    // image, another stylesheet) is a failure like any other.
    if (reason === "net::ERR_ABORTED" && request.resourceType() === "stylesheet" &&
        THEME_STYLESHEET.test(new URL(request.url()).pathname)) {
      observed.abortedThemeLoads.push(request.url());
      return;
    }
    observed.errors.push(`request failed: ${request.url()} (${reason})`);
  });
  page.on("response", (response) => {
    if (response.status() >= 400) observed.errors.push(`HTTP ${response.status()}: ${response.url()}`);
  });
  await page.addInitScript((events) => {
    window.__ctStoryEvents = [];
    let channel;
    Object.defineProperty(window, "__STORYBOOK_ADDONS_CHANNEL__", {
      configurable: true,
      get: () => channel,
      set: (value) => {
        channel = value;
        for (const name of events) {
          value.on(name, (payload) => window.__ctStoryEvents.push({
            name,
            message: payload?.message ?? payload?.description ?? (typeof payload === "string" ? payload : ""),
          }));
        }
      },
    });
  }, STORYBOOK_EVENTS);
  return observed;
}

// settleStory(page, observed, { timeoutMs }) -- after `page.goto`: wait until
// the story has rendered and its view has settled, recording what went wrong
// into `observed.errors`. Ready means: StoryBook announced the end of the
// render (after the play check), no element is still marked
// `data-story-pending` (a mount that loads something on first use, the
// editor's Monaco, marks its host until it is in), and the network idle AND
// the story's DOM unchanged for a second, twice in a row (a loaded host can
// leave gaps between module loads longer than "network idle" waits for).
export async function settleStory(page, observed, { timeoutMs = 90000 } = {}) {
  await page.waitForFunction(() => window.__ctStoryEvents.length > 0, null, { timeout: timeoutMs });
  await page.waitForFunction(() => !document.querySelector("[data-story-pending]"), null, { timeout: 60000 })
    .catch(() => observed.errors.push("still loading after 60 s: an element is still marked data-story-pending"));
  for (let round = 0; round < 2; round++) {
    await page.waitForLoadState("networkidle", { timeout: 30000 }).catch(() => {});
    await page.evaluate(() => new Promise((resolve) => {
      const root = document.querySelector("#storybook-root") ?? document.body;
      let timer = setTimeout(done, 1000);
      const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(done, 1000); });
      const cap = setTimeout(done, 20000);
      function done() { observer.disconnect(); clearTimeout(timer); clearTimeout(cap); resolve(); }
      observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true });
    }));
  }
  // An aborted theme load is excused only when the page went on to load a
  // DIFFERENT theme into `#theme`: the abort was the switch. An abort of
  // the theme the page still names is a stylesheet that never arrived.
  if (observed.abortedThemeLoads.length) {
    const current = await page.evaluate(() => {
      const link = document.getElementById("theme");
      return link ? new URL(link.getAttribute("href"), document.baseURI).href : "";
    });
    for (const url of observed.abortedThemeLoads) {
      if (url === current || !current) observed.errors.push(`request failed: ${url} (net::ERR_ABORTED, and #theme still names it)`);
    }
  }
  for (const event of await page.evaluate(() => window.__ctStoryEvents)) {
    if (event.name !== "storyRendered") observed.errors.push(`StoryBook ${event.name}: ${event.message.slice(0, 300)}`);
  }
}

// inspectRenderedStory(page, story, observed) -> observed.page: what the
// settled story drew, as `judge` reads it.
export async function inspectRenderedStory(page, story, observed) {
  const asSource = (map) => Object.fromEntries(Object.entries(map).map(([k, re]) => [k, [re.source, re.flags]]));
  observed.page = await page.evaluate(inspectStory, {
    statePatterns: asSource(STATE_PATTERNS),
    stateText: asSource(STATE_TEXT),
    messageWording: asSource(MESSAGE_WORDING),
    missingText: MISSING_TEXT,
    missingClass: MISSING_CLASS,
    chrome: CHROME,
    // The names the story is known by: a panel's name drawn as its own
    // title is not content.
    storyTitles: [story.name, story.name?.split(":")[0]].filter(Boolean),
  });
  return observed.page;
}

// renderAndJudge(page, baseUrl, story, theme, opts) -> { observed, failures }.
// The whole sequence on a fresh page: watch it, open the story, settle,
// inspect, judge. A failure to finish is a failure (`error`), never a pass.
// `opts.beforeGoto(page)` runs after the watchers are installed (the render
// check's plants route the bundle there); `opts.afterInspect(page, observed)`
// runs on the settled page before the verdict (the render check's screenshot).
export async function renderAndJudge(page, baseUrl, story, theme, opts = {}) {
  const { timeoutMs = 90000, beforeGoto, afterInspect } = opts;
  const observed = await watchStoryPage(page);
  try {
    if (beforeGoto) await beforeGoto(page);
    await page.goto(storyUrl(baseUrl, story.id, theme), { waitUntil: "load", timeout: timeoutMs });
    await settleStory(page, observed, { timeoutMs });
    await inspectRenderedStory(page, story, observed);
    if (afterInspect) await afterInspect(page, observed);
  } catch (error) {
    observed.errors.push(`did not finish rendering: ${String(error.message ?? error).split("\n")[0]}`);
  }
  return { observed, failures: judge(story, observed) };
}
