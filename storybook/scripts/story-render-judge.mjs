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
//   missing-glyph  A visible character drawn as the missing-glyph box (no
//                face the element names, nor any fallback the machine has,
//                draws it: a control reading as a boxed "?"), or a declared
//                font face that failed to load (an icon font that never
//                arrived).
//                The type-size category also covers the conversation: an
//                agent's reply or the user's message (`.msg-content` in the
//                Agent Activity pane) drawn at another size than the
//                window's body size.
//   icon-ink     A control of the caption bar drawn as an icon (no text of
//                its own: the logo, the debugger toolbar, the window
//                buttons) that paints no mark, or a mark so faint against
//                the control's own background that it reads as none (below
//                2:1; an inert control needs only to show a mark), measured
//                on the rendered pixels.
//   name-cut     A variable's name (`.value-name`, the Variables pane, the
//                Scratchpad, a value popup) drawn cut, with no ellipsis: the
//                name is a fixed part of the row and the value is what gives
//                up width.
//   cut-edge     An Agent Harbor view's cut text breaks the views' one rule
//                for a cut (CTF-P1c D6): a text cut in code
//                (`views/ah_cut_text.nim`, `data-ah-shown`) keeps a space or
//                a separator before its "…" (`ahCutTextDangles`, the shared
//                `agent_harbor_words.danglesBeforeEllipsis`, exported to the
//                page); a text is cut below its floor (`data-ah-floor`,
//                a tree node's counts' `1…`, CTF-P1c D7); a text marked to
//                be cut in code (`data-ah-cut`)
//                overflows and is not cut; or a text in an Agent Harbor view
//                is cut by CSS's `text-overflow: ellipsis`, which cannot
//                drop either. The render check adds what `probeCutTexts`
//                finds: a drawn cut the accessibility tree reads beside its
//                whole text, and, with each tree node's line narrowed, counts
//                below their floor or pushed past the line.
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

import { decodePng } from "../../tools/visual-review/capture-verdicts.mjs";

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
// The categories a verdict can carry. A capture records the ones it was
// judged under (`capture-verdicts.json`), so an image judged before a rule
// existed can be told from one judged under it.
export const JUDGE_RULES = [
  "placeholder", "empty", "error", "type-size", "missing-glyph", "icon-ink", "name-cut", "cut-edge",
];
export const MISSING_TEXT = "No structure story registered";
export const MISSING_CLASS = "ct-storybook-missing";
// Elements whose text is chrome rather than content: controls, tabs and the
// golden-layout header the harness draws around a panel. A drawn read-only
// field (`role=textbox` with `aria-readonly=true`, the composer's form
// values) is an input like any other: its placeholder is the field's, not an
// empty state of the story. Only read-only ones: an editable text box is an
// editor surface whose content the check must still see.
export const CHROME = "button,[role=button],input,select,textarea,[role=textbox][aria-readonly=true],label,[role=tab],[role=toolbar],.lm_header";
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

// `moment` (optional) opens a playback story at one of its scenario's named
// moments: the StoryBook global `moment` (`.storybook/preview.js`), a second
// `key:value` pair in the same `globals` parameter, `;`-separated
// (https://storybook.js.org/docs/essentials/toolbars-and-globals#setting-globals-via-url).
export function storyUrl(baseUrl, storyId, theme, moment = "") {
  const globals = moment ? `theme:${theme};moment:${moment}` : `theme:${theme}`;
  return `${baseUrl.replace(/\/$/, "")}/iframe.html?id=${storyId}&viewMode=story&globals=${globals}`;
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
  // Cut text in an Agent Harbor view (`cut-edge`). A line overflows when
  // its text, as laid out (a Range over it, overflow included), ends past
  // the element's content box.
  const cutTexts = [];
  const overflows = (el) => {
    const box = el.getBoundingClientRect();
    if (box.width <= 0 || !el.textContent) return false;
    const style = getComputedStyle(el);
    const right = box.right - parseFloat(style.borderRightWidth || 0) - parseFloat(style.paddingRight || 0);
    const range = document.createRange();
    range.selectNodeContents(el);
    return range.getBoundingClientRect().right > right + 0.01;
  };
  const AGENT_HARBOR = "[class^='ah-'], [class*=' ah-'], [class*='agent-harbor']";
  for (const el of root.querySelectorAll("*")) {
    if (!visible(el)) continue;
    const shown = el.getAttribute("data-ah-shown");
    if (shown !== null) {
      if (typeof globalThis.ahCutTextDangles !== "function") {
        cutTexts.push({ problem: "cut-rule-missing", text: shown });
      } else if (globalThis.ahCutTextDangles(shown)) {
        cutTexts.push({ problem: "dangles", text: shown, full: el.textContent.slice(0, 120) });
      }
      const floor = el.getAttribute("data-ah-floor");
      if (floor && [...shown].length < [...floor].length) {
        cutTexts.push({ problem: "below-floor", text: shown, floor });
      }
      continue;
    }
    if (!el.closest(AGENT_HARBOR)) continue;
    if (el.hasAttribute("data-ah-cut")) {
      if (overflows(el)) cutTexts.push({ problem: "uncut", text: el.textContent.slice(0, 120) });
    } else if (getComputedStyle(el).textOverflow === "ellipsis" &&
               !/flex|grid/.test(getComputedStyle(el).display) && overflows(el)) {
      // `text-overflow` cuts a block's own inline content; a flex or grid
      // container's children are items it does not cut.
      cutTexts.push({ problem: "css", text: el.textContent.slice(0, 120), cls: el.className });
    }
  }

  // A layout drawn without the harness's panel frames (the standalone app
  // shell) is judged as one box, as a panel is.
  if (contentBoxes.length === 0) contentBoxes.push(pageBox(content, kind || "story"));
  // Missing glyphs: a character no face the element names, and no fallback
  // face the machine has, can draw comes out as the missing-glyph box
  // (".notdef", "tofu"): a control that reads as "?" in a box, or an icon
  // font that never loaded. Each visible character outside ASCII is drawn on
  // a canvas in its element's font and compared with a code point no font
  // has (U+10FFFD, private use, plane 16): drawn identically, it is the box
  // too. Whitespace and format characters draw nothing and are skipped, as
  // is text set at no size (an accessible label kept in the DOM, drawn as
  // an icon). Every story text counts, chrome included: a broken control is
  // broken wherever it is.
  const glyphCanvas = document.createElement("canvas");
  glyphCanvas.width = 48; glyphCanvas.height = 48;
  const glyphContext = glyphCanvas.getContext("2d", { willReadFrequently: true });
  const drawnAs = new Map();
  const pixelsOf = (font, ch) => {
    const key = font + "\u0000" + ch;
    if (drawnAs.has(key)) return drawnAs.get(key);
    glyphContext.clearRect(0, 0, 48, 48);
    glyphContext.font = font;
    glyphContext.fillStyle = "#000";
    glyphContext.fillText(ch, 4, 36);
    const data = glyphContext.getImageData(0, 0, 48, 48).data;
    let ink = 0, hash = 0;
    for (let i = 3; i < data.length; i += 4) { if (data[i]) ink++; hash = (hash * 31 + data[i]) | 0; }
    const value = { ink, hash };
    drawnAs.set(key, value);
    return value;
  };
  const missingGlyphs = [];
  const seenGlyphs = new Set();
  const glyphWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let node = glyphWalker.nextNode(); node; node = glyphWalker.nextNode()) {
    const parent = node.parentElement;
    if (!parent || !visible(parent) || parent.closest(".monaco-editor")) continue;
    const style = getComputedStyle(parent);
    if (parseFloat(style.fontSize) < 2) continue;
    const font = `${style.fontStyle} ${style.fontWeight} 32px ${style.fontFamily}`;
    for (const ch of node.textContent) {
      const code = ch.codePointAt(0);
      if (code < 0x80 || /[\s\p{Cf}\p{Mn}]/u.test(ch)) continue;
      const key = font + "\u0000" + ch;
      if (seenGlyphs.has(key)) continue;
      seenGlyphs.add(key);
      const drawn = pixelsOf(font, ch);
      const box = pixelsOf(font, "\u{10FFFD}");
      if (box.ink > 0 && drawn.ink === box.ink && drawn.hash === box.hash) {
        missingGlyphs.push({ char: ch, code: "U+" + code.toString(16).toUpperCase().padStart(4, "0"),
                             font: style.fontFamily.slice(0, 80), text: lineOf(parent).slice(0, 60) });
      }
    }
  }
  // A face the page declared that failed to load (a missing or broken font
  // file): whatever it was meant to draw falls back, or is a box.
  const failedFonts = [...new Set([...document.fonts].filter((f) => f.status === "error")
    .map((f) => f.family.replace(/["']/g, "")))];
  // The conversation's type size: every message of the Agent Activity pane
  // -- the user's, the agent's while it works, its final reply -- is body
  // text, drawn at the window's size. (Inline code and the tool-call rows
  // inside a message are their own elements and are not measured here.)
  const replySizes = [];
  for (const message of root.querySelectorAll(".agent-msg-wrapper .msg-content")) {
    if (!visible(message) || !lineOf(message)) continue;
    const size = getComputedStyle(message).fontSize;
    if (size !== rootFontSize) replySizes.push({ size, rootSize: rootFontSize, text: lineOf(message).slice(0, 60) });
  }
  // Variable names cut with no ellipsis: the part of a name a person sees
  // ends where the first ancestor that clips it ends (overflow other than
  // visible; a scrolling box does not count, what it hides is reachable).
  // A name is cut when less than all of it shows, and the clipping box draws
  // no `…`.
  const cutNames = [];
  for (const name of root.querySelectorAll(".value-name")) {
    if (!visible(name)) continue;
    const text = name.textContent.replace(/[:\s]+$/, "");
    if (!text) continue;
    const full = name.scrollWidth;
    const left = name.getBoundingClientRect().left;
    let right = left + full;
    let clipper = null;
    for (let a = name; a && a !== root; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (cs.overflowX === "visible" || cs.overflowX === "auto" || cs.overflowX === "scroll") continue;
      const r = a.getBoundingClientRect().right;
      if (r < right) { right = r; clipper = a; }
    }
    const shown = right - left;
    if (shown < full - 1) {
      const ellipsis = [name, clipper].some((e) => e && getComputedStyle(e).textOverflow === "ellipsis");
      if (!ellipsis) cutNames.push({ text: text.slice(0, 60), shown: Math.round(Math.max(0, shown)), full: Math.round(full) });
    }
  }
  // The caption bar's icon controls, for the pixel check of the marks they
  // paint (`measureIconInk`): every visible control in `#menu` with no text
  // of its own. Its content box (inside its border and padding: the logo's
  // button draws a border of its own) is where the mark is drawn.
  const iconControls = [];
  // A control's own text is what a person sees of it: a tooltip it holds,
  // hidden until hover, is not.
  const shownText = (el) => {
    let text = "";
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(); n; n = w.nextNode()) if (n.parentElement && visible(n.parentElement)) text += n.textContent;
    return text.trim();
  };
  for (const el of document.querySelectorAll("#menu button, #menu [role=button], #menu .menu-button-svg")) {
    if (!visible(el) || shownText(el)) continue;
    if (el.parentElement?.closest("#menu button, #menu [role=button], #menu .menu-button-svg")) continue;
    const cs = getComputedStyle(el);
    const b = el.getBoundingClientRect();
    const px = (v) => parseFloat(v) || 0;
    const x = b.left + px(cs.borderLeftWidth) + px(cs.paddingLeft);
    const y = b.top + px(cs.borderTopWidth) + px(cs.paddingTop);
    const width = b.right - px(cs.borderRightWidth) - px(cs.paddingRight) - x;
    const height = b.bottom - px(cs.borderBottomWidth) - px(cs.paddingBottom) - y;
    if (width < 8 || height < 8) continue;
    // Off the window (a toolbar wider than its bar, pushed out at an edge):
    // no one sees it, so it is not judged on pixels.
    if (x + width <= 0 || y + height <= 0 || x >= innerWidth || y >= innerHeight) continue;
    const name = el.id ? "#" + el.id : el.getAttribute("title") || el.getAttribute("aria-label") || el.className.toString().split(" ").pop() || el.tagName.toLowerCase();
    iconControls.push({ name, x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height),
                        inert: el.disabled === true || el.getAttribute("aria-disabled") === "true" });
  }
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
    missingGlyphs,
    failedFonts,
    replySizes,
    cutNames,
    iconControls,
    cutTexts,
    contentBox: { width: Math.round(box.width), height: Math.round(box.height) },
    contentBoxes,
  };
}

// --- The verdict ------------------------------------------------------------------

// The verdict for one rendered story: a list of failures, each with its
// category (one of `JUDGE_RULES`). An empty list is a pass.
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
  for (const c of page.cutTexts ?? []) {
    if (c.problem === "dangles") {
      add("cut-edge", `a cut text keeps a space or a separator before its "…": "${c.text}" (of "${c.full}")`);
    } else if (c.problem === "below-floor") {
      add("cut-edge", `a text is cut to "${c.text}", below its floor "${c.floor}"` +
        (c.width ? ` on a ${c.width}px line` : ""));
    } else if (c.problem === "uncut") {
      add("cut-edge", `a text marked to be cut in code overflows and is not cut: "${c.text}"`);
    } else if (c.problem === "read-twice") {
      add("cut-edge", `a drawn cut is in the accessibility tree beside its whole text, read twice: "${c.text}"`);
    } else if (c.problem === "floor-box") {
      add("cut-edge", `the counts' box is narrower than their floor "${c.floor}" on a ${c.width}px line (${c.detail}): "${c.text}"`);
    } else if (c.problem === "floor-overflow") {
      add("cut-edge", `the counts are pushed past their line on a ${c.width}px line that has room for their floor "${c.floor}" (${c.detail}): the title did not give way`);
    } else if (c.problem === "floor-unreached") {
      add("cut-edge", `narrowing the line never brought the counts to their floor "${c.floor}": "${c.text}"`);
    } else if (c.problem === "css") {
      add("cut-edge", `an Agent Harbor text is cut by CSS's ellipsis, which cannot trim it (.${String(c.cls).split(" ").join(".")}): "${c.text}"`);
    } else {
      add("cut-edge", `a cut text is drawn but the page has no cut rule to check it by: "${c.text}"`);
    }
  }
  for (const t of page.typeSizes ?? []) {
    add("type-size", `the ${t.panel} panel inherits ${t.size}, the window's type size is ${t.rootSize}` +
      " (mounted outside the app's #ROOT > .session-container chain)");
  }
  for (const g of page.missingGlyphs ?? []) {
    add("missing-glyph", `draws ${g.char} (${g.code}) as the missing-glyph box: no face of "${g.font}" nor any fallback has it ("${g.text}")`);
  }
  for (const family of page.failedFonts ?? []) {
    add("missing-glyph", `the font face "${family}" failed to load`);
  }
  for (const r of page.replySizes ?? []) {
    add("type-size", `the Agent Activity message "${r.text}" is drawn at ${r.size}, the window's body size is ${r.rootSize}`);
  }
  for (const icon of page.iconInk ?? []) {
    if (icon.ink < ICON_MIN_INK) {
      add("icon-ink", `the caption bar's ${icon.name} control paints no mark (${icon.ink} pixel(s) apart from its background in its ${icon.width}x${icon.height} box)`);
    } else if (!icon.inert && icon.contrast < ICON_MIN_CONTRAST) {
      add("icon-ink", `the caption bar's ${icon.name} control paints its mark at ${icon.contrast.toFixed(2)}:1 against its background, below ${ICON_MIN_CONTRAST}:1`);
    }
  }
  for (const n of page.cutNames ?? []) {
    add("name-cut", `the variable name "${n.text}" is cut to ${n.shown} of its ${n.full}px with no ellipsis`);
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

// --- The caption bar's marks, on the pixels ---------------------------------------

// A mark is at least this many pixels apart from its control's background.
export const ICON_MIN_INK = 6;
// Below this contrast against its background a mark reads as missing: the
// light theme's near-white window glyphs on the light bar drew at 1.07:1.
// It is the floor for "the control shows its mark", read on pixels, not WCAG
// 2.2 SC 1.4.11's 3:1 between colours
// (https://www.w3.org/TR/WCAG22/#non-text-contrast): a hairline mark never
// reaches its colour on any pixel, so the new-tab "+" (#b0b0b0 on #333333,
// 5.8:1 as colours) draws at 2.7:1 at its strongest pixel, and a 3:1 pixel
// floor would fail a mark whose colours pass.
export const ICON_MIN_CONTRAST = 2;
// A pixel counts as part of the mark when it differs from the background by
// at least this contrast ratio: anti-aliased edges count, noise does not.
const INK_THRESHOLD = 1.25;

// WCAG relative luminance of an sRGB colour (0..255 channels).
// https://www.w3.org/TR/WCAG22/#dfn-relative-luminance
function luminance(r, g, b) {
  const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}
export function contrastRatio(a, b) {
  const la = luminance(...a), lb = luminance(...b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

// iconInkOf(image, box) -> { ink, contrast }: in `box` of a decoded
// screenshot, the background is the colour most pixels have; the mark is
// every pixel at least INK_THRESHOLD apart from it, and its contrast is the
// strongest of them (a stroke's core, not its anti-aliased edge).
export function iconInkOf(image, box) {
  const counts = new Map();
  const at = (x, y) => {
    const o = (y * image.width + x) * image.channels;
    return [image.pixels[o], image.pixels[o + 1], image.pixels[o + 2]];
  };
  const x0 = Math.max(0, box.x), y0 = Math.max(0, box.y);
  const x1 = Math.min(image.width, box.x + box.width), y1 = Math.min(image.height, box.y + box.height);
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const key = at(x, y).join(",");
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  let background = null, most = -1;
  for (const [key, n] of counts) if (n > most) { most = n; background = key.split(",").map(Number); }
  let ink = 0, contrast = 1;
  if (!background) return { ink, contrast };
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const c = contrastRatio(at(x, y), background);
    if (c >= INK_THRESHOLD) { ink++; if (c > contrast) contrast = c; }
  }
  return { ink, contrast };
}

// measureIconInk(page, observed): the marks the caption bar's icon controls
// paint, read from one screenshot of the bar (`observed.page.iconControls`
// names the boxes), into `observed.page.iconInk`.
async function measureIconInk(page, observed) {
  const controls = observed.page?.iconControls ?? [];
  if (controls.length === 0) return;
  const viewport = page.viewportSize();
  const bottom = Math.min(viewport.height, Math.max(...controls.map((c) => c.y + c.height)) + 1);
  const shot = await page.screenshot({ clip: { x: 0, y: 0, width: viewport.width, height: bottom }, animations: "disabled", caret: "hide" });
  const image = decodePng(shot);
  observed.page.iconInk = controls.map((c) => ({ ...c, ...iconInkOf(image, c) }));
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
  await measureIconInk(page, observed);
  return observed.page;
}

// probeCutTexts(page) -> problems, in the shape of `inspectStory`'s
// `cutTexts` (verdict `cut-edge`): what the render check asks of the Agent
// Harbor views' cut texts beyond the one settled frame `inspectStory` reads.
// It changes the page (it narrows tree nodes), so only the render check runs
// it, after its screenshot; the capture tool never does.
//
// - Read once. A cut text keeps its whole text in the DOM and draws the cut
//   over it from `data-ah-shown` (`views/ah_cut_text.nim`); the drawn cut
//   is generated content, which the accessibility tree reads unless the
//   stylesheet gives it empty alternative text (CSS Generated Content 3,
//   https://www.w3.org/TR/css-content-3/#alt). A drawn cut in the tree is a
//   text a screen reader reads twice, whole and cut (`read-twice`).
// - The counts' floor (CTF-P1c D7). Each tree node's counts
//   (`data-ah-floor`, `1…`) are narrowed with their line, down to a line
//   that holds only its fixed parts, the floor and the gaps: at no width may
//   the counts be drawn below their floor or have a box narrower than it
//   (`below-floor`, `floor-box`), be left overflowing and uncut (`uncut`), or,
//   while the line has room for the floor, be pushed past its end because
//   the title kept its half (`floor-overflow`). The sweep must bring the
//   counts to their floor at least once, or it proved nothing
//   (`floor-unreached`). Every width it needs is measured here, from the
//   faces and the boxes, never read from what `ah_cut_text` computed.
export async function probeCutTexts(page) {
  const problems = [];
  const drawn = await page.evaluate(() =>
    [...document.querySelectorAll("[data-ah-shown]")]
      .map((el) => el.getAttribute("data-ah-shown"))
      .filter(Boolean));
  if (drawn.length) {
    const cdp = await page.context().newCDPSession(page);
    try {
      const { nodes } = await cdp.send("Accessibility.getFullAXTree");
      const read = new Set(nodes
        .filter((n) => !n.ignored && n.role?.value === "StaticText")
        .map((n) => n.name?.value ?? ""));
      for (const text of new Set(drawn)) {
        if (read.has(text)) problems.push({ problem: "read-twice", text });
      }
    } finally {
      await cdp.detach().catch(() => {});
    }
  }
  problems.push(...await page.evaluate(async () => {
    const found = [];
    const px = (v) => parseFloat(v) || 0;
    const frames = (n) => new Promise((resolve) => {
      const step = (k) => (k === 0 ? resolve() : requestAnimationFrame(() => step(k - 1)));
      step(n);
    });
    const measurer = document.createElement("span");
    measurer.setAttribute("aria-hidden", "true");
    measurer.style.cssText = "position:absolute;left:-10000px;top:0;visibility:hidden;white-space:pre";
    document.body.appendChild(measurer);
    const advance = (cs, text) => {
      measurer.style.font = cs.font;
      measurer.style.fontFeatureSettings = cs.fontFeatureSettings;
      measurer.style.fontVariantNumeric = cs.fontVariantNumeric;
      measurer.style.letterSpacing = cs.letterSpacing;
      measurer.textContent = text;
      return measurer.getBoundingClientRect().width;
    };
    const counts = [...document.querySelectorAll("[data-ah-floor]")]
      .filter((el) => el.getBoundingClientRect().height > 0 && el.parentElement)
      .slice(0, 3);
    for (const el of counts) {
      const line = el.parentElement;
      const savedStyle = line.getAttribute("style");
      const floor = el.getAttribute("data-ah-floor");
      const cs = getComputedStyle(el);
      const ls = getComputedStyle(line);
      const ownEdges = px(cs.paddingLeft) + px(cs.paddingRight) + px(cs.borderLeftWidth) + px(cs.borderRightWidth);
      const floorBox = advance(cs, floor) + ownEdges;
      const lineEdges = px(ls.paddingLeft) + px(ls.paddingRight) + px(ls.borderLeftWidth) + px(ls.borderRightWidth);
      const items = [...line.children].filter((c) => {
        const s = getComputedStyle(c);
        return s.display !== "none" && s.position !== "absolute" && s.position !== "fixed";
      });
      // What the line needs beside its cut texts: its fixed parts, the
      // counts' floor and the gaps.
      let rest = floorBox + px(ls.columnGap) * Math.max(0, items.length - 1);
      for (const c of items) if (!c.hasAttribute("data-ah-cut")) rest += c.getBoundingClientRect().width;
      const whole = line.getBoundingClientRect().width;
      const widths = [whole * 0.6, whole * 0.45, whole * 0.3,
                      rest + lineEdges + 48, rest + lineEdges + 24, rest + lineEdges + 12, rest + lineEdges + 4]
        .map(Math.round).filter((w) => w > 0 && w < whole);
      let reached = false;
      for (const w of widths) {
        line.style.flex = "none";
        line.style.width = line.style.minWidth = line.style.maxWidth = `${w}px`;
        await frames(4);
        const lineBox = line.getBoundingClientRect();
        const room = lineBox.width - lineEdges;
        const lineRight = lineBox.right - px(ls.paddingRight) - px(ls.borderRightWidth);
        const box = el.getBoundingClientRect();
        const shown = el.getAttribute("data-ah-shown") ?? el.textContent;
        if (shown === floor) reached = true;
        if ([...shown].length < [...floor].length) {
          found.push({ problem: "below-floor", text: shown, floor, width: w });
        }
        if (!el.hasAttribute("data-ah-shown")) {
          const range = document.createRange();
          range.selectNodeContents(el);
          if (range.getBoundingClientRect().right > box.right - px(cs.paddingRight) - px(cs.borderRightWidth) + 0.01) {
            found.push({ problem: "uncut", text: `${el.textContent} (its line ${w}px wide)` });
          }
        }
        if (room >= rest + 1) {
          if (box.width + 0.5 < floorBox) {
            found.push({ problem: "floor-box", text: shown, floor, width: w,
                         detail: `${box.width.toFixed(1)}px < ${floorBox.toFixed(1)}px` });
          }
          if (box.right > lineRight + 0.5) {
            found.push({ problem: "floor-overflow", text: shown, floor, width: w,
                         detail: `${(box.right - lineRight).toFixed(1)}px past the line` });
          }
        }
      }
      if (savedStyle === null) line.removeAttribute("style"); else line.setAttribute("style", savedStyle);
      await frames(4);
      if (widths.length && !reached) {
        found.push({ problem: "floor-unreached", text: el.textContent, floor });
      }
    }
    measurer.remove();
    return found;
  }));
  return problems;
}

// renderAndJudge(page, baseUrl, story, theme, opts) -> { observed, failures }.
// The whole sequence on a fresh page: watch it, open the story, settle,
// inspect, judge. A failure to finish is a failure (`error`), never a pass.
// `opts.beforeGoto(page)` runs after the watchers are installed (the render
// check's plants route the bundle there); `opts.afterInspect(page, observed)`
// runs on the settled page before the verdict (the render check's screenshot).
// `opts.moment` opens a playback story at that named moment (`storyUrl`).
export async function renderAndJudge(page, baseUrl, story, theme, opts = {}) {
  const { timeoutMs = 90000, beforeGoto, afterInspect, moment = "" } = opts;
  const observed = await watchStoryPage(page);
  try {
    if (beforeGoto) await beforeGoto(page);
    await page.goto(storyUrl(baseUrl, story.id, theme, moment), { waitUntil: "load", timeout: timeoutMs });
    await settleStory(page, observed, { timeoutMs });
    await inspectRenderedStory(page, story, observed);
    if (afterInspect) await afterInspect(page, observed);
  } catch (error) {
    observed.errors.push(`did not finish rendering: ${String(error.message ?? error).split("\n")[0]}`);
  }
  return { observed, failures: judge(story, observed) };
}
