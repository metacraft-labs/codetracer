/**
 * plat47-editor-languages-capture.spec.ts — which Monaco language the REAL
 * desktop EDITOR opens each sample file in.
 *
 * `plat47-monaco-lexers-capture.spec.ts` asks the desktop's Monaco how it
 * tokenises one sample per language, naming the language itself. That says
 * nothing about the EDITOR: until 2026-09-30 the editor picked its Monaco
 * language from the recording-language table (`common_lang.toCLang`), which
 * has no spelling for `.ts`, `.java`, `.sh`, `.json` or `.yaml`, so those files
 * opened as `unknown` and were drawn in one colour while the terminal and GPUI
 * coloured them with Monaco's own definitions.
 *
 * This spec opens the desktop in edit mode on a folder holding exactly the
 * samples (`src/frontend/tui/tests/fixtures/monaco_lexers/`), opens each one
 * from the Files pane as a user does, and records the language id of the
 * Monaco model the editor created for it (`model.getLanguageId()`) and the
 * number of distinct token types Monaco produced for its text in that language
 * (a file opened in a language with no tokenizer has none).
 *
 * Written to `src/tests/visual/answers/plat47-editor-languages.electron.json`;
 * `src/frontend/tui/tests/test_plat47_monaco_lexers.nim` asserts every sample
 * opened in the language the terminal lexes it as.
 *
 * No mocks: the real `ct edit`, the real Electron app, the real Files pane.
 * The prefix (this checkout's desktop JavaScript) comes from
 * `scripts/plat45-desktop-prefix.sh` via `PLAT47_DESKTOP_PREFIX`.
 */

import * as fs from "fs";
import * as path from "path";

import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat47-editor-languages.electron.json");
const samplesDir = path.join(repoRoot, "src", "frontend", "tui", "tests", "fixtures", "monaco_lexers");

function sampleFolder(): string {
  fs.mkdirSync(path.join(repoRoot, "test-logs"), { recursive: true });
  const dir = fs.mkdtempSync(path.join(repoRoot, "test-logs", "plat47-editor-languages-"));
  for (const name of fs.readdirSync(samplesDir)) {
    fs.copyFileSync(path.join(samplesDir, name), path.join(dir, name));
  }
  return dir;
}

const folder = sampleFolder();
const names = fs.readdirSync(folder).sort();

test.use({
  launchMode: "edit",
  editFolderPath: folder,
  editWorkingDirectory: folder,
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT47_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);
test.afterAll(() => {
  fs.rmSync(folder, { recursive: true, force: true });
});

test("PLAT-47: the desktop editor opens every sample in its Monaco language", async ({ ctPage }) => {
  await ctPage.waitForFunction(
    () => typeof (globalThis as any).monaco !== "undefined",
    { timeout: 90_000 },
  );
  const files = ctPage.locator("div[id^='filesystemComponent']").first();
  await files.waitFor({ timeout: 90_000 });

  const opened: Record<string, { language: string; tokenTypes: number }> = {};
  for (const name of names) {
    // Open it from the Files pane, as a user does.
    await files.getByText(name, { exact: true }).first().click();
    // The editor tab for the file, as the desktop keeps it: `data.ui.editors`
    // is keyed by path, and each tab holds the Monaco editor it created.
    const found = await ctPage.waitForFunction(
      (want) => {
        const editors = (globalThis as any).data?.ui?.editors ?? {};
        for (const key of Object.keys(editors)) {
          if (!key.endsWith("/" + want)) continue;
          const model = editors[key]?.monacoEditor?.getModel?.();
          if (model) return model.getLanguageId();
        }
        return null;
      },
      name,
      { timeout: 60_000 },
    );
    const language = (await found.jsonValue()) as string;
    const tokenTypes = await ctPage.evaluate(
      async ({ want, lang }) => {
        const m = (globalThis as any).monaco;
        const editors = (globalThis as any).data.ui.editors;
        const key = Object.keys(editors).find((k) => k.endsWith("/" + want)) as string;
        const model = editors[key].monacoEditor.getModel();
        // A lazily loaded tokenizer (JSON's) answers once it has loaded.
        let types = new Set<string>();
        for (let attempt = 0; attempt < 50; attempt++) {
          types = new Set<string>();
          for (const line of m.editor.tokenize(model.getValue(), lang)) {
            for (const t of line) if (t.type !== "") types.add(t.type);
          }
          if (types.size > 0) break;
          await new Promise((r) => setTimeout(r, 200));
        }
        return types.size;
      },
      { want: name, lang: language },
    );
    opened[name] = { language, tokenTypes };
  }

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify({
    takenAt: new Date().toISOString(),
    samples: opened,
  }, null, 1) + "\n");
});
