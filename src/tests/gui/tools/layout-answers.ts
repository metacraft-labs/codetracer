/**
 * layout-answers.ts — PLAT-35. **The Electron front-end's answers to the eight
 * layout questions, read out of ITS OWN rendered DOM.**
 *
 * ## The one rule this file exists to obey
 *
 * `Verification-Harness-Traps` §30a: *if one side's answer is derived from the
 * other's, all questions agree and nothing is compared.* So nothing here reads
 * the GPUI front-end, the GPUI producer, or an expected value. Every answer
 * comes from the live document: `getBoundingClientRect`, `getComputedStyle`,
 * and the classes and `data-*` attributes the product's own renderer put on the
 * elements.
 *
 * The sibling producer is `src/frontend/view_vocabulary/gpui_layout_answers.nim`,
 * which reads the Rust shadow tree and the projected dock document.
 * `ci/test/plat35-answer-independence.sh` is the source scan that keeps the two
 * apart, and it is aimed at the BODIES rather than at these headers.
 *
 * ## What IS shared, and why that is not the same thing
 *
 * The QUESTION IDS, the canonical spelling of an answer, and the token-id and
 * metric-bucket alphabets — all published in
 * `src/common/view_vocabulary/layout_questions.nim` and in
 * `codetracer-specs/Testing/Cross-Renderer-Visual-Alignment.md` §3. Sharing a
 * vocabulary is what makes two independently-read answers comparable at all;
 * sharing a reader would make them one answer read twice.
 *
 * The spellings are transcribed here because TypeScript cannot import a Nim
 * const, and that transcription is the one place these two files could drift.
 *
 * ## HOW THE TRANSCRIPTION IS GUARDED, STATED EXACTLY
 *
 * This header used to say that *"the question ids are compared against the
 * published oracle table in both directions"*. **`LAYOUT_QUESTIONS` below was
 * compared to nothing, in either direction, by anything.** The two-direction
 * comparison in the Nim suite is the published §3 table against the
 * `LayoutQuestion` ENUM; this array is a third spelling of the same eight
 * names and no check looked at it. Corrected 2026-09-21 rather than deleted,
 * because what actually guards it is worth writing down:
 *
 *   * **the VALUES this file writes are read back by name.** The Nim gate
 *     reads `<scenario>.electron.json` through `answerSetFromJson`, which maps
 *     each `question` string through `questionFromKey`. A key renamed here and
 *     not in the enum does not match, and `unknownQuestionKeys` reports it —
 *     the suite asserts that report is EMPTY, per scenario. That is the guard,
 *     and it did not exist either until 2026-09-21: the reader `continue`d
 *     past an unknown id in silence, which is the §4 shape.
 *   * **the CARDINALITY is asserted per scenario, on both arms**, by `the two
 *     front-ends each emit all eight questions, per scenario`. A subset of six
 *     perfectly-spelled ids fails there.
 *
 * So the array below is not itself compared; what it PRODUCES is. A rename
 * here fails by name in the Nim gate rather than by silently comparing
 * nothing — which is what the old sentence claimed and what is now true.
 */

import type { Page } from "playwright";

/** Matches `CaptureTier` in `layout_questions.nim`. */
export type CaptureTier = "captured" | "source reading";

/** The eight canonical keys of `Cross-Renderer-Visual-Alignment.md` §3. */
export const LAYOUT_QUESTIONS = [
  "pane-rectangles",
  "which-panes-are-present",
  "editor-row-count",
  "gutter-marks-by-line",
  "inline-value-runs-by-line",
  "text-metrics-per-role",
  "token-colour-per-role",
  "focus-order",
] as const;

export type LayoutQuestion = (typeof LAYOUT_QUESTIONS)[number];

/**
 * `Unanswered` in `layout_questions.nim`. **A front-end that cannot answer a
 * question says so with this** — it is a value and never a missing key,
 * because a comparison over the keys both sides happen to have is satisfied by
 * two sides that answer nothing (§4).
 */
export const UNANSWERED = "<unanswered>";

export interface LayoutAnswer {
  question: LayoutQuestion;
  value: string;
  tier: CaptureTier;
}

export interface LayoutAnswerSet {
  frontEnd: "electron";
  scenario: string;
  answers: LayoutAnswer[];
}

/**
 * Extract all eight answers from a live CodeTracer window.
 *
 * Everything runs inside ONE `page.evaluate`, deliberately: the eight answers
 * must describe one frame. Eight round trips would let a re-render land between
 * question three and question four, and a set of answers from two different
 * screens is exactly the "green fixture describing a state no shipped route can
 * reach" shape the traps document names.
 */
export async function extractLayoutAnswers(
  page: Page,
  scenario: string,
): Promise<LayoutAnswerSet> {
  const answers = await page.evaluate(() => {
    const UNANSWERED_IN_PAGE = "<unanswered>";

    // -- shared helpers, INSIDE the page ------------------------------------

    // The DOM id is `<paneName>Component[-<index>]`; the model's pane id is
    // `<paneName>` (`layout_model.PaneKind`'s own display strings). The mapping
    // is a STRIP rather than a table, so a pane added to the product does not
    // need an entry here before it can be reported — a table would silently
    // drop it, and a dropped pane is how "the two front-ends agree" becomes
    // true by subtraction.
    //
    // ANCHORED AT BOTH ENDS. A substring test for `Component` also matches
    // `editorComponent-0-inner` and every nested wrapper GoldenLayout builds,
    // and the first run of this extractor reported `calltrace`, `state`,
    // `filesystem` and `eventLog` TWICE each for exactly that reason. A pane
    // reported twice is not a cosmetic defect: it makes the answer depend on
    // how many wrappers the DOM happens to have, which is the one thing a
    // cross-renderer answer must not depend on.
    const PANE_ID = /^([A-Za-z]+)Component(-\d+)?$/;

    const paneIdOf = (el: Element): string => {
      const m = PANE_ID.exec(el.id || "");
      return m ? m[1] : "";
    };

    const paneRoots = (): HTMLElement[] => {
      const best = new Map<string, HTMLElement>();
      const w = window.innerWidth;
      const h = window.innerHeight;
      document.querySelectorAll<HTMLElement>("div[id]").forEach((el) => {
        const pane = paneIdOf(el);
        if (pane.length === 0) return;
        const r = el.getBoundingClientRect();
        // A pane with no area is a pane the user cannot see: GoldenLayout keeps
        // the non-active member of a stack in the DOM at zero size, and keeps a
        // closed pane parked off-canvas at a negative offset. Both are the same
        // answer the GPUI side gives for a non-active tab — absent — so both
        // are dropped here rather than reported as a rectangle of zeros, which
        // would make "present" mean "in the document" on one front-end and "on
        // the screen" on the other.
        if (r.width < 2 || r.height < 2) return;
        if (r.right <= 0 || r.bottom <= 0 || r.left >= w || r.top >= h) return;
        // Keep the LARGEST element for a pane id. Nested wrappers share the id
        // prefix; the outermost is the pane.
        const prev = best.get(pane);
        if (prev) {
          const pr = prev.getBoundingClientRect();
          if (pr.width * pr.height >= r.width * r.height) return;
        }
        best.set(pane, el);
      });
      // Document order, which is what the stacking/tab-order and focus-order
      // questions are about.
      const all = Array.from(best.values());
      all.sort((a, b) => {
        const rel = a.compareDocumentPosition(b);
        // eslint-disable-next-line no-bitwise
        if (rel & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
        // eslint-disable-next-line no-bitwise
        if (rel & Node.DOCUMENT_POSITION_PRECEDING) return 1;
        return 0;
      });
      return all;
    };

    const round = (n: number) => Math.round(n);

    // -- Q1: pane rectangles, in a normalised coordinate space --------------

    const q1 = (): string => {
      const w = window.innerWidth;
      const h = window.innerHeight;
      if (w <= 0 || h <= 0) return UNANSWERED_IN_PAGE;
      const parts: string[] = [];
      for (const el of paneRoots()) {
        const r = el.getBoundingClientRect();
        parts.push(
          `${paneIdOf(el)}=${round((r.left * 100) / w)},` +
            `${round((r.top * 100) / h)},` +
            `${round((r.width * 100) / w)},` +
            `${round((r.height * 100) / h)}`,
        );
      }
      if (parts.length === 0) return UNANSWERED_IN_PAGE;
      parts.sort();
      return parts.join(";");
    };

    // -- Q2: which panes are present, and their stacking/tab order ----------

    const q2 = (): string => {
      const parts: string[] = [];
      for (const el of paneRoots()) {
        // GoldenLayout's stack header is `.lm_tabs`; a pane not inside one is
        // a tab group of one, which is the same reconciliation the GPUI side
        // makes (gpui-kit has no bare-leaf container either).
        const stack = el.closest(".lm_stack");
        const tabs = stack ? stack.querySelectorAll(".lm_tab") : null;
        const tabCount = tabs && tabs.length > 0 ? tabs.length : 1;
        let active = 0;
        if (tabs) {
          tabs.forEach((t, i) => {
            if (t.classList.contains("lm_active")) active = i;
          });
        }
        parts.push(`${paneIdOf(el)}@${active}/${tabCount}`);
      }
      if (parts.length === 0) return UNANSWERED_IN_PAGE;
      return parts.join(",");
    };

    // -- the editor, shared by Q3..Q5 ---------------------------------------
    //
    // MONACO DOES NOT PUT A LINE NUMBER ON `.view-line`. The divs are
    // absolutely positioned and reordered on scroll; the number lives on the
    // gutter, and the K-th gutter child pairs with the K-th `.view-line`
    // (`page-objects/panes/editor/editor-pane.ts` documents the same pairing).
    // That is filed as `PLAT35-VG2` rather than worked around silently.

    const editorRoot = (): HTMLElement | null =>
      document.querySelector<HTMLElement>("div[id^='editorComponent']");

    const gutters = (root: HTMLElement): HTMLElement[] =>
      Array.from(
        root.querySelectorAll<HTMLElement>(
          ".monaco-editor .margin-view-overlays .gutter",
        ),
      ).sort((a, b) => {
        const la = parseInt(a.dataset.line || "0", 10);
        const lb = parseInt(b.dataset.line || "0", 10);
        return la - lb;
      });

    const viewLines = (root: HTMLElement): HTMLElement[] =>
      Array.from(
        root.querySelectorAll<HTMLElement>(".monaco-editor .view-lines .view-line"),
      ).sort((a, b) => a.offsetTop - b.offsetTop);

    const q3 = (): string => {
      const root = editorRoot();
      if (!root) return UNANSWERED_IN_PAGE;
      const g = gutters(root);
      const v = viewLines(root);
      if (g.length === 0 || v.length === 0) return UNANSWERED_IN_PAGE;
      const lines = g
        .map((el) => parseInt(el.dataset.line || "-1", 10))
        .filter((n) => n > 0);
      if (lines.length === 0) return UNANSWERED_IN_PAGE;
      return `rows=${v.length};first=${Math.min(...lines)};last=${Math.max(...lines)}`;
    };

    const q4 = (): string => {
      const root = editorRoot();
      if (!root) return UNANSWERED_IN_PAGE;
      const g = gutters(root);
      if (g.length === 0) return UNANSWERED_IN_PAGE;
      const parts: string[] = [];
      for (const el of g) {
        const line = parseInt(el.dataset.line || "-1", 10);
        if (line <= 0) continue;
        const names: string[] = [];
        // The precedence is the row model's own: an execution pointer outranks
        // a mark on the same line, because a line that is both is a line the
        // debugger is stopped on and a user reads the stop first.
        if (el.querySelector(".gutter-highlight-active")) names.push("execution");
        if (el.querySelector(".gutter-breakpoint-enabled")) names.push("breakpoint");
        else if (el.querySelector(".gutter-breakpoint-disabled"))
          names.push("breakpoint-disabled");
        if (
          el.querySelector(".gutter-trace") ||
          el.querySelector(".gutter-disabled-trace")
        )
          names.push("tracepoint");
        if (names.length > 0) parts.push(`${line}=${names.join("+")}`);
      }
      // AN EMPTY MARK SET IS A LEGITIMATE ANSWER and is deliberately not
      // `UNANSWERED`: a file with no breakpoints and no stop has no marks.
      return parts.join(";");
    };

    const q5 = (): string => {
      const root = editorRoot();
      if (!root) return UNANSWERED_IN_PAGE;
      const v = viewLines(root);
      const g = gutters(root);
      if (v.length === 0 || g.length === 0) return UNANSWERED_IN_PAGE;
      const parts: string[] = [];
      for (let i = 0; i < v.length && i < g.length; i++) {
        const line = parseInt(g[i].dataset.line || "-1", 10);
        if (line <= 0) continue;
        const chips = Array.from(v[i].querySelectorAll<HTMLElement>(".ct-omni-value"));
        if (chips.length === 0) continue;
        const values: string[] = [];
        for (const chip of chips) {
          const name = chip.querySelector(".ct-omni-name")?.textContent ?? "";
          const box = chip.querySelector(
            ".flow-parallel-value-box, .flow-inline-value-box, .flow-multiline-value-box",
          );
          values.push(`${name.trim()}=${(box?.textContent ?? "").trim()}`);
        }
        parts.push(`${line}:${values.length}:${values.join("|")}`);
      }
      return parts.join(";");
    };

    // -- Q6 and Q7: text metrics and token colour, per role ------------------
    //
    // The roles are the closed set `layout_questions.nim` publishes. Each is
    // located by the selector the PRODUCT's own renderer emits, and its metric
    // is MEASURED out of `getComputedStyle` rather than declared — which is why
    // this side's `text-metrics-per-role` row is `captured` and the GPUI side's
    // is a `source reading` (`PLAT35-VG1`).

    const ROLE_SELECTORS: [string, string][] = [
      ["editor-code", "div[id^='editorComponent'] .monaco-editor .view-line"],
      [
        "gutter-line-number",
        "div[id^='editorComponent'] .margin-view-overlays .gutter-line",
      ],
      ["pane-title", ".lm_stack .lm_tab.lm_active .lm_title"],
      ["value-name", "div[id^='stateComponent'] .value-name"],
      ["value-text", "div[id^='stateComponent'] .value-view"],
    ];

    const familyClass = (family: string): string =>
      /mono|consol|courier|menlo|dejavu sans mono|ubuntu mono/i.test(family)
        ? "mono"
        : "proportional";

    const sizeBucket = (px: number): string =>
      px < 12.5 ? "sm" : px < 17.5 ? "md" : "lg";

    const weightBucket = (weight: string): string => {
      const n = parseInt(weight, 10);
      const w = Number.isNaN(n) ? (weight === "bold" ? 700 : 400) : n;
      return w >= 600 ? "bold" : w >= 500 ? "medium" : "regular";
    };

    const q6 = (): string => {
      const parts: string[] = [];
      for (const [role, selector] of ROLE_SELECTORS) {
        const el = document.querySelector<HTMLElement>(selector);
        if (!el) continue;
        const cs = window.getComputedStyle(el);
        parts.push(
          `${role}=${familyClass(cs.fontFamily)}/` +
            `${sizeBucket(parseFloat(cs.fontSize))}/` +
            `${weightBucket(cs.fontWeight)}`,
        );
      }
      if (parts.length === 0) return UNANSWERED_IN_PAGE;
      return parts.join(";");
    };

    /**
     * THE CLASS THE TOKEN RESOLVES TO, never the hex value — §3.1. The mapping
     * from a rendered class to a design-system token id is published in
     * `Cross-Renderer-Visual-Alignment.md` §3.1b and is an ORACLE rather than a
     * producer: which role carries which class is this front-end's own
     * rendering decision and is read off the element.
     */
    const q7 = (): string => {
      const parts: string[] = [];
      const editor = editorRoot();
      if (editor) {
        const stopped = editor.querySelector(
          ".monaco-editor .view-overlays .current-line",
        );
        parts.push(
          `editor-code=${stopped ? "editor.executionLine.background" : "editor.code.foreground"}`,
        );
        const g = gutters(editor);
        let gutterToken = "editor.lineNumber.foreground";
        for (const el of g) {
          if (el.querySelector(".gutter-breakpoint-enabled")) {
            gutterToken = "gutter.breakpoint.enabled";
            break;
          }
          if (el.querySelector(".gutter-breakpoint-disabled")) {
            gutterToken = "gutter.breakpoint.disabled";
            break;
          }
          if (el.querySelector(".gutter-trace")) {
            gutterToken = "gutter.tracepoint";
            break;
          }
        }
        parts.push(`gutter-line-number=${gutterToken}`);
      }
      if (document.querySelector(".lm_stack .lm_tab.lm_active .lm_title"))
        parts.push("pane-title=pane.title.foreground");
      if (document.querySelector("div[id^='stateComponent'] .value-name"))
        parts.push("value-name=value.name.foreground");
      if (document.querySelector("div[id^='stateComponent'] .value-view"))
        parts.push("value-text=value.text.foreground");
      if (parts.length === 0) return UNANSWERED_IN_PAGE;
      return parts.join(";");
    };

    // -- Q8: focus order ----------------------------------------------------

    const q8 = (): string => {
      const roots = paneRoots();
      if (roots.length === 0) return UNANSWERED_IN_PAGE;
      const ranked = roots.map((el, i) => {
        const raw = el.getAttribute("tabindex");
        const t = raw === null ? 0 : parseInt(raw, 10);
        return { pane: paneIdOf(el), tab: Number.isNaN(t) ? 0 : t, order: i };
      });
      // The DOM's own rule: a positive `tabindex` comes first in ascending
      // order, then everything else in document order.
      ranked.sort((a, b) => {
        const pa = a.tab > 0 ? 0 : 1;
        const pb = b.tab > 0 ? 0 : 1;
        if (pa !== pb) return pa - pb;
        if (pa === 0 && a.tab !== b.tab) return a.tab - b.tab;
        return a.order - b.order;
      });
      return ranked.map((r) => r.pane).join(",");
    };

    return {
      "pane-rectangles": q1(),
      "which-panes-are-present": q2(),
      "editor-row-count": q3(),
      "gutter-marks-by-line": q4(),
      "inline-value-runs-by-line": q5(),
      "text-metrics-per-role": q6(),
      "token-colour-per-role": q7(),
      "focus-order": q8(),
    } as Record<LayoutQuestion, string>;
  });

  return {
    frontEnd: "electron",
    scenario,
    // ALL EIGHT, ALWAYS, in the published order. A question this front-end
    // could not answer carries `UNANSWERED`; it is never a missing row.
    answers: LAYOUT_QUESTIONS.map((question) => ({
      question,
      value: answers[question] ?? UNANSWERED,
      // Every row on this side is a CAPTURE: it was read off a document a
      // shipped `ct` binary rendered in this run. The GPUI side's
      // `text-metrics-per-role` row is a source reading and says so; mixing
      // the two without labelling them is the tier violation PLAT-23 wrote the
      // rule for.
      tier: "captured" as CaptureTier,
    })),
  };
}
