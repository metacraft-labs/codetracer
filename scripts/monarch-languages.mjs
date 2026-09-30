#!/usr/bin/env node
// monarch-languages.mjs — export Monaco's own Monarch language definitions
// (the tokenizers the desktop's editor colours source with) as plain JSON the
// terminal's highlighter interprets (`src/frontend/tui/app/syntax/monarch.nim`).
//
//   node scripts/monarch-languages.mjs <out.json>
//
// The definitions are read from the pinned `monaco-editor` in `node_modules`
// (the same version `src/public/third_party/monaco-editor` links), so the
// terminal and the desktop tokenise with ONE set of rules. What this script
// does is exactly what Monaco's `monarchCompile.compile` does before a rule can
// run, and nothing more, so the JSON is data rather than a second opinion:
//
//   * every `include` is expanded in place (`addRules`);
//   * every `@attr` inside a regex is replaced by `(?:<attr>)`, `@@` is a
//     literal `@`, up to five rounds (`compileRegExp`); a `$Sn` is LEFT in
//     the source, because Monarch substitutes it per state at run time;
//   * a rule whose regex starts with `^` is "match only at line start" and
//     loses the `^` (`Rule.setRegex`);
//   * a `[regex, token, next]` rule becomes `{token, next}`;
//   * the lexer's options take Monarch's defaults (`tokenPostfix` = `.<id>`,
//     `defaultToken` = `source`, ...), and `brackets` Monarch's default table.
//
// Actions stay symbolic: a `cases` table is exported as its ordered
// `[guard, action]` pairs, and `monarch.nim` evaluates guards the way
// `createGuard` does. Every string-array attribute is exported (a guard's
// `@keywords` names one), every string attribute (a token's `@attr`) and every
// regex attribute's source (a guard's `~regex` may name one).
//
// The regex sources are JavaScript regular expressions; `monarch.nim` carries
// the matcher for the subset they use.
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath, pathToFileURL } from "url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const basic = path.join(repo, "node_modules", "monaco-editor", "esm", "vs", "basic-languages");
const pkg = JSON.parse(fs.readFileSync(path.join(repo, "node_modules", "monaco-editor", "package.json"), "utf8"));

// The Monaco language ids the terminal tokenises with. `javascript` extends
// `typescript`, so both files are staged.
const LANGUAGES = ["python", "rust", "cpp", "go", "typescript", "javascript", "java", "ruby", "shell", "yaml"];

// Stage each module as `.mjs` in a scratch directory, with the one import a
// language file makes of the editor API replaced by the only member its
// `conf` reads (`languages.IndentAction`), so node can evaluate it without the
// editor. `language` — the only export used here — reads nothing from it.
const stage = fs.mkdtempSync(path.join(os.tmpdir(), "monarch-"));
const EDITOR_API = /import \* as monaco_editor_core_star from "\.\.\/\.\.\/editor\/editor\.api\.js";/;
const STUB = "var monaco_editor_core_star = { languages: { IndentAction: { None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3 } } };";
for (const id of LANGUAGES) {
  let text = fs.readFileSync(path.join(basic, id, id + ".js"), "utf8");
  if (EDITOR_API.test(text)) {
    text = STUB + "\n" + text.replace(EDITOR_API, "");
  }
  text = text.replace(/from "\.\.\/(\w+)\/(\w+)\.js"/g, 'from "./$2.mjs"');
  fs.writeFileSync(path.join(stage, id + ".mjs"), text);
}

function source(re) {
  return typeof re === "string" ? re : re.source;
}

// monarchCompile.compileRegExp's expansion, without the RegExp construction.
function expand(json, str) {
  str = str.replace(/@@/g, "\x01");
  let n = 0;
  let had;
  do {
    had = false;
    str = str.replace(/@(\w+)/g, (s, attr) => {
      had = true;
      let sub = "";
      if (typeof json[attr] === "string") sub = json[attr];
      else if (json[attr] instanceof RegExp) sub = json[attr].source;
      else throw new Error(`language definition does not contain a string/regex attribute '${attr}' (${str})`);
      return sub ? "(?:" + sub + ")" : "";
    });
    n++;
  } while (had && n < 5);
  return str.replace(/\x01/g, "@");
}

function action(json, act) {
  if (act === undefined || act === null) return { token: "" };
  if (typeof act === "string") return act;
  if (Array.isArray(act)) return { group: act.map((a) => action(json, a)) };
  if (act.cases) {
    const cases = [];
    for (const key of Object.keys(act.cases)) cases.push([key, action(json, act.cases[key])]);
    return { cases };
  }
  if (act.token !== undefined) {
    const out = { token: act.token };
    for (const k of ["next", "switchTo", "goBack", "bracket", "nextEmbedded"]) {
      if (act[k] !== undefined) out[k] = act[k];
    }
    if (typeof out.next === "string" && !/^(@pop|@push|@popall)$/.test(out.next) && out.next[0] === "@") {
      out.next = out.next.substr(1);
    }
    return out;
  }
  throw new Error("unsupported action: " + JSON.stringify(act));
}

function rules(json, rulesIn, out) {
  for (const rule of rulesIn) {
    if (rule.include) {
      const inc = rule.include[0] === "@" ? rule.include.substr(1) : rule.include;
      rules(json, json.tokenizer[inc], out);
      continue;
    }
    let re;
    let act;
    let atStartOverride;
    if (Array.isArray(rule)) {
      re = source(rule[0]);
      if (rule.length >= 3) {
        act = typeof rule[1] === "string" ? { token: rule[1], next: rule[2] } : { ...rule[1], next: rule[2] };
      } else {
        act = rule[1];
      }
    } else {
      re = source(rule.regex);
      act = rule.action;
      if (rule.matchOnlyAtStart) atStartOverride = !!rule.matchOnlyAtLineStart;
    }
    const atStart = re.length > 0 && re[0] === "^";
    out.push({
      re: expand(json, atStart ? re.substr(1) : re),
      atStart: atStartOverride === undefined ? atStart : atStartOverride,
      action: action(json, act),
    });
  }
  return out;
}

const result = { monacoVersion: pkg.version, languages: {} };
for (const id of LANGUAGES) {
  const mod = await import(pathToFileURL(path.join(stage, id + ".mjs")).href);
  const json = mod.language;
  const words = {};
  const strings = {};
  const regexes = {};
  for (const [k, v] of Object.entries(json)) {
    if (k === "tokenizer" || k === "brackets") continue;
    if (Array.isArray(v) && v.every((e) => typeof e === "string")) words[k] = v;
    else if (typeof v === "string") strings[k] = v;
    else if (v instanceof RegExp) regexes[k] = v.source;
  }
  const states = {};
  let start = typeof json.start === "string" ? json.start : null;
  for (const key of Object.keys(json.tokenizer)) {
    if (!start) start = key;
    states[key] = rules(json, json.tokenizer[key], []);
  }
  const postfix = typeof json.tokenPostfix === "string" ? json.tokenPostfix : "." + id;
  const brackets = (json.brackets ?? [
    { open: "{", close: "}", token: "delimiter.curly" },
    { open: "[", close: "]", token: "delimiter.square" },
    { open: "(", close: ")", token: "delimiter.parenthesis" },
    { open: "<", close: ">", token: "delimiter.angle" },
  ]).map((b) => (Array.isArray(b) ? { open: b[0], close: b[1], token: b[2] } : b))
    .map((b) => ({ open: b.open, close: b.close, token: b.token + postfix }));
  result.languages[id] = {
    ignoreCase: !!json.ignoreCase,
    unicode: !!json.unicode,
    includeLF: !!json.includeLF,
    tokenPostfix: postfix,
    defaultToken: typeof json.defaultToken === "string" ? json.defaultToken : "source",
    start,
    brackets,
    words,
    strings,
    regexes,
    states,
  };
}
fs.rmSync(stage, { recursive: true, force: true });
const out = process.argv[2];
const text = JSON.stringify(result) + "\n";
if (out) fs.writeFileSync(out, text);
else process.stdout.write(text);
