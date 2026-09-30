/**
 * plat47-monaco-lexers-capture.spec.ts — PLAT-47 B4's desktop column: how the
 * REAL Electron front-end's Monaco tokenises one sample file per language the
 * terminal lexes.
 *
 * For every file in `src/frontend/tui/tests/fixtures/monaco_lexers/` the
 * running desktop's own `monaco.editor.tokenize` is asked for the file's
 * tokens, in the Monaco language that tokenizer belongs to (`rust` for Rust and
 * for Noir — the desktop's editor opens `.nr` as Rust —, `c`, `cpp`, `go`,
 * `javascript`, `typescript`, `java`, `ruby`, `shell`, `json`, `yaml`,
 * `python`). Each token is recorded as `[offset, type]`, per line, exactly as
 * Monaco answers it.
 *
 * Written to `src/tests/visual/answers/plat47-monaco-lexers.electron.json`.
 * `src/frontend/tui/tests/test_plat47_monaco_lexers.nim` reads it and compares
 * the terminal's tokens with it CHARACTER BY CHARACTER; it fails by name when
 * the file is absent, naming `just plat47-capture-electron`.
 *
 * Also recorded: which language ids this Monaco has registered. (The
 * desktop's editor itself opens `.ts`, `.java`, `.sh`, `.json` and `.yaml` as
 * plain text today — its extension table maps them to no Monaco language —
 * which is filed as a desktop issue; the terminal uses the tokenizer Monaco
 * has for each language.)
 *
 * TOML has no Monaco tokenizer at all; its sample is recorded as the plain
 * text Monaco draws it as (`plaintext`).
 *
 * No mocks: the real Electron app on the real `calc` recording, whose Monaco
 * instance is the one the desktop colours source with.
 */

import * as fs from "fs";
import * as path from "path";

import { test } from "../../lib/fixtures";

const repoRoot = path.resolve(__dirname, "..", "..", "..", "..", "..");
const answersDir = path.join(repoRoot, "src", "tests", "visual", "answers");
const answersFile = path.join(answersDir, "plat47-monaco-lexers.electron.json");
const samplesDir = path.join(repoRoot, "src", "frontend", "tui", "tests", "fixtures", "monaco_lexers");

/** The Monaco language each sample is tokenised in. */
const LANGUAGE_OF: Record<string, string> = {
  ".rs": "rust",
  ".nr": "rust",
  ".c": "c",
  ".cpp": "cpp",
  ".go": "go",
  ".js": "javascript",
  ".ts": "typescript",
  ".java": "java",
  ".rb": "ruby",
  ".sh": "shell",
  ".json": "json",
  ".yaml": "yaml",
  ".toml": "plaintext",
  ".py": "python",
};

function recording(): string {
  const cache = path.join(repoRoot, "test-logs", "tui-fixtures");
  const hits = fs.existsSync(cache)
    ? fs.readdirSync(cache).filter((e) => e.startsWith("calc-")).sort()
    : [];
  if (hits.length === 0) {
    throw new Error(
      "PLAT-47: the 'calc' recording is not in test-logs/tui-fixtures/; run 'just test-tui' once to record it.",
    );
  }
  return path.join(cache, hits[hits.length - 1]);
}

test.use({
  sourcePath: recording(),
  launchMode: "trace-folder",
  noUserLayout: true,
  codetracerPrefixOverride: process.env.PLAT47_DESKTOP_PREFIX ?? "",
});
test.setTimeout(300_000);

test("PLAT-47 B4: the desktop's Monaco tokenizers on one sample per language", async ({ ctPage }) => {
  await ctPage.waitForSelector(".view-line", { timeout: 90_000 });

  const samples: { name: string; language: string; text: string }[] = [];
  for (const name of fs.readdirSync(samplesDir).sort()) {
    const ext = path.extname(name);
    const language = LANGUAGE_OF[ext];
    if (!language) continue;
    samples.push({ name, language, text: fs.readFileSync(path.join(samplesDir, name), "utf8") });
  }

  const captured = await ctPage.evaluate(async (list) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const m = (window as any).monaco;
    const registered: string[] = m.languages.getLanguages().map((l: { id: string }) => l.id);
    // A language whose tokenizer loads lazily (JSON's lives in its language
    // service) is only tokenised once a model in it exists and the load has
    // run: create one, then wait until tokenize stops answering one plain
    // token per line.
    const out: Record<string, unknown> = {};
    for (const s of list) {
      let lines: unknown[] = [];
      if (s.language !== "plaintext") {
        const model = m.editor.createModel(s.text, s.language);
        for (let attempt = 0; attempt < 50; attempt++) {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          lines = m.editor.tokenize(s.text, s.language).map((line: any[]) =>
            line.map((t) => [t.offset, t.type]));
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const typed = (lines as any[]).some((line) => line.some((t: [number, string]) => t[1] !== ""));
          if (typed) break;
          await new Promise((r) => setTimeout(r, 200));
        }
        model.dispose();
      } else {
        lines = s.text.split("\n").map(() => [[0, ""]]);
      }
      out[s.name] = { language: s.language, lines };
    }
    return { registered, samples: out };
  }, samples);

  fs.mkdirSync(answersDir, { recursive: true });
  fs.writeFileSync(answersFile, JSON.stringify({
    takenAt: new Date().toISOString(),
    registered: captured.registered,
    samples: captured.samples,
  }, null, 1) + "\n");
});
