/**
 * The editor differential: the same scenario on the desktop with Monaco and
 * with the shared editor (the `sharedEditor` developer setting) gives the same
 * observations. Real app, real `replay-server`, real recording; the input is
 * Playwright's trusted mouse and keyboard; no mocks.
 *
 * The scenario is DATA (`lib/editor-differential.ts`'s steps), shaped for the
 * scenario format so it moves into the CodeTracer page-object pack unchanged:
 * open a recording, read the editor, click into a line, double-click a word,
 * set a breakpoint in the glyph column, step, and read again at each point.
 *
 * The two runs are two launches (one per editor) in one serial block; the
 * third test compares what they saw, observation by observation.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { expect, test } from "../../lib/fixtures";
import {
  activeEditorIsShared, editorReady, runEditorScenario,
  type EditorObservation, type ScenarioStep,
} from "../../lib/editor-differential";
import { originFixturePath, pythonSpecSkipReason } from "../../lib/value-origin-fixtures";

const SOURCE = originFixturePath("python", "simple_trivial_chain");

/** The scenario. Line and column numbers are the fixture's. */
const EDITOR_STEPS: ScenarioStep[] = [
  { kind: "settle", ms: 1500 },
  { kind: "observe", label: "opened at the first stop" },
  { kind: "click", line: 9, column: 5 },
  { kind: "observe", label: "a click places the caret" },
  { kind: "click", line: 12, column: 6, count: 2 },
  { kind: "observe", label: "a double click selects the word" },
  { kind: "glyph", line: 11 },
  { kind: "observe", label: "the glyph column sets a breakpoint" },
  { kind: "press", keys: "Escape" },
  { kind: "press", keys: "F10" },
  { kind: "settle", ms: 2500 },
  { kind: "observe", label: "a step moves the execution pointer" },
  { kind: "press", keys: "Shift+ArrowDown" },
  { kind: "observe", label: "Shift+Down extends the selection" },
  { kind: "click", line: 9, column: 5 },
  { kind: "press", keys: "Control+F" },
  { kind: "type", text: "print" },
  { kind: "press", keys: "Enter" },
  { kind: "press", keys: "Escape" },
  { kind: "observe", label: "find selects the match and Escape keeps it" },
];

const OUT = path.join(process.cwd(), "test-results", "editor-differential");

function save(editor: string, obs: EditorObservation[]) {
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, `${editor}.json`), JSON.stringify(obs, null, 2));
}

test.beforeAll(() => {
  const reason = pythonSpecSkipReason();
  test.skip(reason !== null, reason ?? "");
});

test.describe.serial("the same scenario on both editors", () => {
  test.setTimeout(300_000);

  test.describe("with Monaco", () => {
    test.use({ sourcePath: SOURCE, launchMode: "trace",
               launchEnv: { CODETRACER_SHARED_EDITOR: "0" } });
    test("runs the scenario", async ({ ctPage: page }) => {
      await editorReady(page);
      expect(await activeEditorIsShared(page)).toBe(false);
      save("monaco", await runEditorScenario(page, EDITOR_STEPS));
    });
  });

  test.describe("with the shared editor", () => {
    test.use({ sourcePath: SOURCE, launchMode: "trace",
               launchEnv: { CODETRACER_SHARED_EDITOR: "1" } });
    test("runs the scenario", async ({ ctPage: page }) => {
      await editorReady(page);
      expect(await activeEditorIsShared(page)).toBe(true);
      save("shared", await runEditorScenario(page, EDITOR_STEPS));
    });
  });

  test("the two editors observed the same", () => {
    const monaco: EditorObservation[] = JSON.parse(
      fs.readFileSync(path.join(OUT, "monaco.json"), "utf8"));
    const shared: EditorObservation[] = JSON.parse(
      fs.readFileSync(path.join(OUT, "shared.json"), "utf8"));
    expect(shared.map((o) => o.label)).toEqual(monaco.map((o) => o.label));
    for (let i = 0; i < monaco.length; i++) {
      const label = monaco[i].label;
      // The drawn window may differ in its edges (the editors' viewports are
      // measured independently); the lines BOTH draw read the same.
      const sharedLines = new Map(shared[i].lines.map((l) => [l.split(":")[0], l]));
      for (const line of monaco[i].lines) {
        const key = line.split(":")[0];
        if (sharedLines.has(key)) {
          expect.soft(sharedLines.get(key), `${label}: line ${key}`).toBe(line);
        }
      }
      expect.soft(shared[i].executionLine, `${label}: the execution line`)
        .toBe(monaco[i].executionLine);
      expect.soft(shared[i].glyphs, `${label}: the glyph column`).toEqual(monaco[i].glyphs);
      expect.soft(shared[i].activeLine, `${label}: the active line number`)
        .toBe(monaco[i].activeLine);
      expect.soft(shared[i].caret, `${label}: the caret`).toEqual(monaco[i].caret);
      expect.soft(shared[i].selections, `${label}: the selection`).toEqual(monaco[i].selections);
      expect.soft(shared[i].values, `${label}: the value chips`).toEqual(monaco[i].values);
    }
  });
});
