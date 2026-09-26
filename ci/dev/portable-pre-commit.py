#!/usr/bin/env python3
"""portable-pre-commit.py -- run the checks nix/pre-commit.nix declares, without Nix.

WHY THIS EXISTS
---------------
The repository's commit-time checks are declared once, in nix/pre-commit.nix,
and git-hooks.nix turns that declaration into a `.pre-commit-config.yaml`
symlink into /nix/store plus a hook shim whose shebang is a /nix/store bash.
Neither exists on native Windows. What a Windows developer got instead was one
of two things, depending on history:

  * a `.repro-local` hook left behind by a Nix shell sharing the checkout, which
    dies with "bad interpreter" (exit 126) and names no way out; or
  * no `.repro-local` at all (a clone that never saw Nix), in which case the
    reprobuild dispatcher has no local layer to run and every commit is
    accepted having checked nothing.

This script is the non-Nix leg of the SAME declaration. It reads
nix/pre-commit.nix itself (a small evaluator for the subset of Nix that file is
written in -- see `NixSubset`), fills in the defaults git-hooks.nix supplies for
its built-in hooks (`BUILTINS`), and hands the result to the real `pre-commit`
framework, at the version Nix pins, with `language: system` -- the same
framework, the same file selection, the same stash-unstaged-changes behaviour
as the Nix path. There is no second list of hooks to keep in step.

WHAT MAY NOT HAPPEN QUIETLY
---------------------------
  * A hook nix/pre-commit.nix enables that this file cannot render is an error
    at generation time, naming the hook. It is never dropped.
  * A construct in nix/pre-commit.nix outside the supported subset is an error
    naming the line, not a best-effort guess.
  * Every generated hook runs through `exec`, which checks that the hook's
    tools exist BEFORE running it. A missing tool fails that hook, by name,
    with the command that installs it. `pre-commit`'s own "Executable not
    found" would also fail, but would not say what to do about it.
  * `bash` resolving to the WSL launcher (C:\\Windows\\System32\\bash.exe) is a
    failure, not a silent detour into a Linux distribution.

LOCKSTEP WITH THE NIX PATH
--------------------------
`compare <config.json>` diffs what this script generates against the config
git-hooks.nix generated (the dev shell's `.pre-commit-config.yaml`), hook by
hook and field by field, with /nix/store prefixes stripped from entries. The
only hand-maintained copy of anything is `BUILTINS` -- the defaults of the
git-hooks.nix built-ins this repository enables, transcribed from
cachix/git-hooks.nix@3bbec39 (the revision flake.lock pins) -- and `compare` is
what keeps it honest. Contract suite: ci/test/portable-pre-commit-test.sh.

Subcommands:
  generate [--runtime]          print the config (canonical, or as executed)
  compare <nix-config.json>     lockstep check against git-hooks.nix's output
  hook <type> --hook-dir D -- ARGS   run as the <type> git hook (installed shim)
  exec <hook-id> -- ARGV...     run one hook's command, after a tool check
  doctor                        list every hook, its tools, and what is missing
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
# Overridable so the contract suite can feed the evaluator fixtures; nothing
# else sets it.
NIX_CONFIG = Path(os.environ.get("CODETRACER_PRE_COMMIT_NIX") or REPO_ROOT / "nix" / "pre-commit.nix")

# The pre-commit framework version nixpkgs (flake.lock) ships, and the
# pre-commit-hooks package the git-hooks.nix built-ins run. Advisory: they are
# what the remedies below install, so the non-Nix path runs what the Nix path
# runs. `hook` reports it when the installed framework differs.
PRE_COMMIT_VERSION = "4.3.0"
PRE_COMMIT_HOOKS_VERSION = "6.0.0"
PIP_REMEDY = (
    f"python -m pip install --user pre-commit=={PRE_COMMIT_VERSION} "
    f"pre-commit-hooks=={PRE_COMMIT_HOOKS_VERSION}"
)

PREFIX = "codetracer pre-commit"


def say(msg: str) -> None:
    print(f"{PREFIX}: {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# A Nix evaluator for the subset nix/pre-commit.nix is written in.
#
# Supported: a lambda with a set pattern (`{ pkgs, x ? null, }: body`), `let
# ... in`, attribute sets with dotted paths (`a.b = v;`), lists, "..." and
# ''...'' strings WITHOUT interpolation, true/false/null, integers, and
# variable references. A reference that reaches a lambda argument (`pkgs.foo`)
# evaluates to an opaque marker: it is only ever used for `extraPackages`,
# which this path ignores because the tools come from PATH.
#
# Anything else -- function application, operators, `inherit`, `with`, `if`,
# `${...}` interpolation -- raises NixSubsetError naming the line. The file can
# grow those; when it does, this fails loudly and has to be taught, which is
# the correct outcome for a parser whose silence would mean a skipped check.
# ---------------------------------------------------------------------------


class NixSubsetError(Exception):
    pass


class Opaque:
    """A value from outside the file (a lambda argument such as `pkgs`)."""

    def __init__(self, path: str):
        self.path = path

    def __repr__(self) -> str:
        return f"<{self.path}>"


_PUNCT = set("{}[]()=;:,?.@")


def _strip_indented(raw: str) -> str:
    # Nix ''...'' semantics: drop a first line that is only whitespace, then
    # remove the smallest indentation shared by the non-blank lines. A final
    # whitespace-only line (the one before the closing '') becomes empty.
    lines = raw.split("\n")
    if lines and lines[0].strip(" ") == "":
        lines = lines[1:]
    indents = [len(ln) - len(ln.lstrip(" ")) for ln in lines if ln.strip(" ")]
    cut = min(indents) if indents else 0
    out = []
    for ln in lines:
        out.append(ln[cut:] if ln.strip(" ") else "")
    return "\n".join(out)


class NixSubset:
    def __init__(self, text: str):
        self.toks = self._lex(text)
        self.i = 0

    # -- lexer --------------------------------------------------------------
    def _lex(self, s: str):
        toks = []
        i, n, line = 0, len(s), 1
        while i < n:
            c = s[i]
            if c == "\n":
                line += 1
                i += 1
            elif c in " \t\r":
                i += 1
            elif c == "#":
                while i < n and s[i] != "\n":
                    i += 1
            elif s.startswith("/*", i):
                j = s.find("*/", i + 2)
                if j < 0:
                    raise NixSubsetError(f"line {line}: unterminated comment")
                line += s.count("\n", i, j)
                i = j + 2
            elif c == '"':
                start_line = line
                j, buf = i + 1, []
                while True:
                    if j >= n:
                        raise NixSubsetError(f"line {start_line}: unterminated string")
                    ch = s[j]
                    if ch == "\\":
                        nxt = s[j + 1]
                        buf.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                        j += 2
                        continue
                    if ch == "$" and s.startswith("${", j):
                        raise NixSubsetError(
                            f"line {line}: string interpolation is outside the "
                            "subset ci/dev/portable-pre-commit.py evaluates"
                        )
                    if ch == '"':
                        break
                    if ch == "\n":
                        line += 1
                    buf.append(ch)
                    j += 1
                toks.append(("str", "".join(buf), start_line))
                i = j + 1
            elif s.startswith("''", i):
                start_line = line
                j, raw = i + 2, []
                while True:
                    if j >= n:
                        raise NixSubsetError(f"line {start_line}: unterminated '' string")
                    if s.startswith("''", j):
                        after = s[j + 2] if j + 2 < n else ""
                        if after == "'":
                            raw.append("''")
                            j += 3
                            continue
                        if after == "$":
                            raw.append("$")
                            j += 3
                            continue
                        if after == "\\":
                            esc = s[j + 3]
                            raw.append({"n": "\n", "t": "\t", "r": "\r"}.get(esc, esc))
                            j += 4
                            continue
                        break
                    if s.startswith("${", j):
                        raise NixSubsetError(
                            f"line {line}: string interpolation is outside the "
                            "subset ci/dev/portable-pre-commit.py evaluates"
                        )
                    if s[j] == "\n":
                        line += 1
                    raw.append(s[j])
                    j += 1
                toks.append(("str", _strip_indented("".join(raw)), start_line))
                i = j + 2
            elif s.startswith("...", i):
                toks.append(("...", "...", line))
                i += 3
            elif c.isalpha() or c == "_":
                j = i + 1
                while j < n and (s[j].isalnum() or s[j] in "_'-"):
                    j += 1
                toks.append(("id", s[i:j], line))
                i = j
            elif c.isdigit():
                j = i
                while j < n and s[j].isdigit():
                    j += 1
                toks.append(("int", int(s[i:j]), line))
                i = j
            elif c in _PUNCT:
                toks.append((c, c, line))
                i += 1
            else:
                raise NixSubsetError(
                    f"line {line}: '{c}' is outside the subset "
                    "ci/dev/portable-pre-commit.py evaluates"
                )
        toks.append(("eof", None, line))
        return toks

    # -- parser/evaluator ---------------------------------------------------
    def peek(self, k: int = 0):
        return self.toks[self.i + k]

    def take(self, kind: str | None = None):
        t = self.toks[self.i]
        if kind is not None and t[0] != kind:
            raise NixSubsetError(
                f"line {t[2]}: expected '{kind}', found '{t[1]}' -- outside the "
                "subset ci/dev/portable-pre-commit.py evaluates"
            )
        self.i += 1
        return t

    def parse(self):
        v = self.expr({})
        if self.peek()[0] != "eof":
            t = self.peek()
            raise NixSubsetError(f"line {t[2]}: unexpected '{t[1]}' after the expression")
        return v

    def _is_lambda_pattern(self) -> bool:
        # `{` then `}` `:`, or `{` ident followed by `,` `?` `}` -- an attrset
        # would have `=` or `.` there instead.
        if self.peek()[0] != "{":
            return False
        a = self.peek(1)
        if a[0] == "}":
            return self.peek(2)[0] == ":"
        return a[0] in ("id", "...") and self.peek(2)[0] in (",", "?", "}")

    def expr(self, env):
        t = self.peek()
        if self._is_lambda_pattern():
            self.take("{")
            args = {}
            while self.peek()[0] != "}":
                if self.peek()[0] == "...":
                    self.take()
                else:
                    name = self.take("id")[1]
                    if self.peek()[0] == "?":
                        self.take("?")
                        self.expr(env)  # default: evaluated for syntax only
                    args[name] = Opaque(name)
                if self.peek()[0] == ",":
                    self.take(",")
            self.take("}")
            self.take(":")
            return self.expr({**env, **args})
        if t[0] == "id" and t[1] == "let":
            self.take()
            scope = dict(env)
            while not (self.peek()[0] == "id" and self.peek()[1] == "in"):
                name = self.take("id")[1]
                self.take("=")
                scope[name] = self.expr(scope)
                self.take(";")
            self.take("id")
            return self.expr(scope)
        return self.select(env)

    def select(self, env):
        v = self.atom(env)
        while self.peek()[0] == ".":
            self.take(".")
            key = self.take("id")[1]
            if isinstance(v, Opaque):
                v = Opaque(v.path + "." + key)
            elif isinstance(v, dict) and key in v:
                v = v[key]
            else:
                raise NixSubsetError(f"line {self.peek()[2]}: no attribute '{key}'")
        nxt = self.peek()
        if nxt[0] in ("id", "str", "int", "{", "[", "(") and not (
            nxt[0] == "id" and nxt[1] in ("in",)
        ):
            raise NixSubsetError(
                f"line {nxt[2]}: function application is outside the subset "
                "ci/dev/portable-pre-commit.py evaluates"
            )
        return v

    def atom(self, env):
        t = self.take()
        kind, val, line = t
        if kind == "str" or kind == "int":
            return val
        if kind == "id":
            if val in ("true", "false"):
                return val == "true"
            if val == "null":
                return None
            if val in ("inherit", "with", "if", "rec", "assert", "import"):
                raise NixSubsetError(
                    f"line {line}: '{val}' is outside the subset "
                    "ci/dev/portable-pre-commit.py evaluates"
                )
            if val not in env:
                raise NixSubsetError(f"line {line}: undefined variable '{val}'")
            return env[val]
        if kind == "(":
            v = self.expr(env)
            self.take(")")
            return v
        if kind == "[":
            items = []
            while self.peek()[0] != "]":
                items.append(self.select_no_apply(env))
            self.take("]")
            return items
        if kind == "{":
            out: dict = {}
            while self.peek()[0] != "}":
                path = [self._attr_name()]
                while self.peek()[0] == ".":
                    self.take(".")
                    path.append(self._attr_name())
                self.take("=")
                value = self.expr(env)
                self.take(";")
                cur = out
                for key in path[:-1]:
                    nxt = cur.setdefault(key, {})
                    if not isinstance(nxt, dict):
                        raise NixSubsetError(f"line {line}: attribute '{key}' defined twice")
                    cur = nxt
                last = path[-1]
                if last in cur:
                    if isinstance(cur[last], dict) and isinstance(value, dict):
                        cur[last] = {**cur[last], **value}
                    else:
                        raise NixSubsetError(f"line {line}: attribute '{last}' defined twice")
                else:
                    cur[last] = value
            self.take("}")
            return out
        raise NixSubsetError(
            f"line {line}: '{val}' is outside the subset ci/dev/portable-pre-commit.py evaluates"
        )

    def select_no_apply(self, env):
        # List elements are juxtaposed, so `[ a b ]` is two elements, not an
        # application: parse one atom plus its `.attr` selections only.
        v = self.atom(env)
        while self.peek()[0] == ".":
            self.take(".")
            key = self.take("id")[1]
            v = Opaque(v.path + "." + key) if isinstance(v, Opaque) else v[key]
        return v

    def _attr_name(self) -> str:
        t = self.take()
        if t[0] in ("id", "str"):
            return t[1]
        raise NixSubsetError(f"line {t[2]}: expected an attribute name, found '{t[1]}'")


def load_nix_settings(path: Path = NIX_CONFIG) -> dict:
    value = NixSubset(path.read_text(encoding="utf-8")).parse()
    if not isinstance(value, dict) or "hooks" not in value:
        raise NixSubsetError(f"{path}: expected an attribute set with `hooks`")
    return value


# ---------------------------------------------------------------------------
# git-hooks.nix built-ins, as cachix/git-hooks.nix@3bbec39 defines them (the
# revision flake.lock's `git-hooks-nix` input pins). Only the fields a hook's
# `raw` form exposes, with `${package}/bin/` removed from entries. A built-in
# whose default entry is not reproducible outside Nix has `entry: None`: the
# repository must set `entry` itself for that hook, and does.
#
# `compare` is what checks these transcriptions against a real evaluation.
# Until one is available on a host without Nix, the next best check was made on
# 2026-09-23: every field below was read against modules/hooks.nix, hook.nix
# and pre-commit.nix at that revision (builtins are applied per field with
# mkDefault, so a field the repository sets replaces, never extends, these),
# and a config derived independently from that source compared identical --
# once trim-trailing-whitespace's own `stages` was added. The contract suite
# pins those `stages`. Changing the git-hooks-nix pin means re-reading them.
# ---------------------------------------------------------------------------

BUILTINS: dict[str, dict] = {
    "shellcheck": {"name": "shellcheck", "entry": "shellcheck", "types": ["shell"]},
    "shfmt": {"name": "shfmt", "entry": "shfmt -w -l -ln auto -s", "types": ["shell"]},
    "nixfmt-rfc-style": {"name": "nixfmt-rfc-style", "entry": "nixfmt", "files": "\\.nix$"},
    "taplo": {"name": "taplo", "entry": "taplo fmt", "types": ["toml"]},
    # Upstream gives this one, like check-added-large-files, its own `stages`:
    # it runs at pre-push too, and that is what makes git-hooks.nix install a
    # pre-push hook at all.
    "trim-trailing-whitespace": {
        "name": "trim-trailing-whitespace",
        "entry": "trailing-whitespace-fixer",
        "types": ["text"],
        "stages": ["pre-commit", "pre-push", "manual"],
    },
    "end-of-file-fixer": {
        "name": "end-of-file-fixer",
        "entry": "end-of-file-fixer",
        "types": ["text"],
    },
    "check-yaml": {"name": "check-yaml", "entry": "check-yaml --multi", "types": ["yaml"]},
    "check-added-large-files": {
        "name": "check-added-large-files",
        "entry": "check-added-large-files",
        "stages": ["pre-commit", "pre-push", "manual"],
    },
    # Built-ins whose defaults depend on Nix-side settings; the repository
    # overrides every field that matters.
    "clippy": {"name": "clippy", "entry": None, "files": "\\.rs$", "pass_filenames": False},
    "cargo-check": {"name": "cargo-check", "entry": None, "files": "\\.rs$", "pass_filenames": False},
    "rustfmt": {"name": "rustfmt", "entry": None, "files": "\\.rs$", "pass_filenames": False},
    "cspell": {"name": "cspell", "entry": "cspell"},
}

# hook.nix option defaults (the `raw` field set).
RAW_DEFAULTS = {
    "language": "system",
    "files": "",
    "types": ["file"],
    "types_or": [],
    "exclude_types": [],
    "pass_filenames": True,
    "fail_fast": False,
    "require_serial": False,
    "verbose": False,
    "always_run": False,
    "args": [],
}
RAW_FIELDS = [
    "id", "name", "entry", "language", "files", "types", "types_or",
    "exclude_types", "pass_filenames", "fail_fast", "require_serial",
    "stages", "verbose", "always_run", "args", "exclude",
]
# Fields nix/pre-commit.nix may set that the generated config does not carry.
NIX_ONLY_FIELDS = {"enable", "extraPackages", "package", "description", "excludes",
                   "settings", "packageOverrides", "before", "after"}


def merge_excludes(excludes: list) -> str:
    # git-hooks.nix's mergeExcludes, verbatim.
    return "^$" if not excludes else "(" + "|".join(excludes) + ")"


def canonical_config(settings: dict | None = None) -> dict:
    """The config git-hooks.nix would generate, with tools named, not stored."""
    settings = settings if settings is not None else load_nix_settings()
    default_stages = settings.get("default_stages", ["pre-commit"])
    hooks = []
    for hook_id in sorted(settings["hooks"]):
        spec = settings["hooks"][hook_id]
        if not isinstance(spec, dict):
            raise NixSubsetError(f"hooks.{hook_id}: expected an attribute set")
        if not spec.get("enable", False):
            continue
        unknown = set(spec) - set(RAW_FIELDS) - NIX_ONLY_FIELDS
        if unknown:
            raise NixSubsetError(
                f"hooks.{hook_id}: field(s) {sorted(unknown)} are not rendered by "
                "ci/dev/portable-pre-commit.py; teach it before relying on them"
            )
        builtin = BUILTINS.get(hook_id)
        if builtin is None and "entry" not in spec:
            raise NixSubsetError(
                f"hooks.{hook_id} is a git-hooks.nix built-in that "
                "ci/dev/portable-pre-commit.py has no definition for. Add it to "
                "BUILTINS (and run `compare` against a Nix-generated config) -- "
                "it will not be skipped."
            )
        raw = {"id": hook_id, "name": hook_id, **RAW_DEFAULTS, "stages": list(default_stages)}
        raw.update({k: v for k, v in (builtin or {}).items()})
        raw.update({k: v for k, v in spec.items() if k in RAW_FIELDS})
        if raw.get("entry") is None:
            raise NixSubsetError(
                f"hooks.{hook_id}: the git-hooks.nix default entry for this built-in "
                "depends on Nix settings; nix/pre-commit.nix must set `entry`"
            )
        raw["exclude"] = merge_excludes(spec.get("excludes", []))
        for opaque_key in [k for k, v in raw.items() if isinstance(v, Opaque)]:
            raise NixSubsetError(f"hooks.{hook_id}.{opaque_key}: depends on {raw[opaque_key]}")
        hooks.append({k: raw[k] for k in RAW_FIELDS})
    config: dict = {"repos": [{"repo": "local", "hooks": hooks}]}
    if settings.get("excludes"):
        config["exclude"] = merge_excludes(settings["excludes"])
    if default_stages:
        config["default_stages"] = list(default_stages)
    return config


# ---------------------------------------------------------------------------
# Tools: how each program a hook names is found on this host, and what to run
# when it is not there.
# ---------------------------------------------------------------------------

# pre-commit-hooks console scripts, run as modules of the interpreter that runs
# this file so a `pip install --user` Scripts directory need not be on PATH.
PY_MODULE_TOOLS = {
    "trailing-whitespace-fixer": "pre_commit_hooks.trailing_whitespace_fixer",
    "end-of-file-fixer": "pre_commit_hooks.end_of_file_fixer",
    "check-yaml": "pre_commit_hooks.check_yaml",
    "check-added-large-files": "pre_commit_hooks.check_added_large_files",
}

REMEDIES = {
    "bash": "install Git for Windows and put its usr\\bin ahead of C:\\Windows\\System32 on PATH "
            "(`. .\\env.ps1` does this)",
    "cargo": "install the Rust toolchain (`. .\\env.ps1` provisions the pinned one on Windows; "
             "elsewhere https://rustup.rs)",
    "cargo-fmt": "rustup component add rustfmt",
    "cargo-clippy": "rustup component add clippy",
    "cspell": "npm install -g cspell@9.2.1",
    "markdownlint-cli2": "npm install -g markdownlint-cli2@0.18.1",
    "shellcheck": "scoop install shellcheck  (Nix pins ShellCheck 0.11)",
    "shfmt": "scoop install shfmt@3.12.0  (the version Nix pins; the hook runs `shfmt -w -l -ln auto -s`)",
    "taplo": "cargo install taplo-cli --locked --version 0.10.0",
    "nixfmt": "nixfmt has no native Windows build. Format the file from a Nix host "
              "(`nix develop --command nixfmt <file>`), or commit the .nix change from one",
    "git": "install Git for Windows",
}
for _tool in PY_MODULE_TOOLS:
    REMEDIES[_tool] = PIP_REMEDY

# Extra programs a hook needs beyond its first word. `cargo fmt` fails with
# "no such command" when the component is missing -- loud, but not actionable.
EXTRA_TOOLS = {
    "rustfmt": ["cargo-fmt"],
    "clippy": ["cargo-clippy"],
}

_WORD_TOOLS_IN_BASH = re.compile(r"\b(cargo|cspell|markdownlint-cli2|grep|git)\b")


def tools_for(hook: dict) -> list[str]:
    argv = shlex.split(hook["entry"])
    tools = [argv[0]]
    if argv[0] == "bash" and len(argv) > 2 and argv[1] == "-c":
        for m in _WORD_TOOLS_IN_BASH.finditer(argv[2]):
            if m.group(1) not in tools:
                tools.append(m.group(1))
    tools += [t for t in EXTRA_TOOLS.get(hook["id"], []) if t not in tools]
    return tools


def _is_wsl_launcher(path: str) -> bool:
    if os.name != "nt":
        return False
    p = os.path.normcase(os.path.abspath(path))
    windir = os.path.normcase(os.environ.get("SystemRoot", r"C:\Windows"))
    return p.startswith(os.path.join(windir, "system32")) or "windowsapps" in p


def resolve_tool(tool: str) -> tuple[list[str] | None, str]:
    """(argv prefix to run `tool`, problem). Exactly one of them is set."""
    module = PY_MODULE_TOOLS.get(tool)
    if module is not None:
        import importlib.util

        if importlib.util.find_spec(module.split(".")[0]) is None:
            return None, f"the Python package providing `{tool}` (pre-commit-hooks) is not installed"
        return [sys.executable, "-m", module], ""
    found = shutil.which(tool)
    if found is None:
        return None, f"`{tool}` is not on PATH"
    if tool == "bash" and _is_wsl_launcher(found):
        return None, (f"`bash` resolves to {found}, the WSL launcher, which would run this "
                      "check inside a Linux distribution instead of on this checkout")
    return [found], ""


def missing_tools(hook: dict) -> list[tuple[str, str]]:
    out = []
    for tool in tools_for(hook):
        argv, problem = resolve_tool(tool)
        if argv is None:
            out.append((tool, problem))
    return out


def runtime_config(config: dict) -> dict:
    """The canonical config with every entry routed through `exec`."""
    me = Path(__file__).resolve().as_posix()
    py = Path(sys.executable).as_posix()
    rt = json.loads(json.dumps(config))
    for hook in rt["repos"][0]["hooks"]:
        hook["entry"] = shlex.join([py, me, "exec", hook["id"], "--"]) + " " + hook["entry"]
    return rt


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_generate(args: list[str]) -> int:
    config = canonical_config()
    if "--runtime" in args:
        config = runtime_config(config)
    json.dump(config, sys.stdout, indent=2)
    print()
    return 0


_STORE_BIN = re.compile(r"/nix/store/[0-9a-z]{32}-[^/\s]+/bin/")


def normalize_nix_hook(hook: dict) -> dict:
    out = dict(hook)
    out.pop("priority", None)
    out["entry"] = " ".join(_STORE_BIN.sub("", hook["entry"]).split())
    return out


def cmd_compare(args: list[str]) -> int:
    if len(args) != 1:
        say("usage: compare <git-hooks.nix-generated config.json>")
        return 2
    nix = json.loads(Path(args[0]).read_text(encoding="utf-8"))
    mine = canonical_config()
    problems = []
    for key in ("exclude", "default_stages"):
        if nix.get(key) != mine.get(key):
            problems.append(f"top-level `{key}` differs:\n    nix:      {nix.get(key)!r}\n"
                            f"    portable: {mine.get(key)!r}")
    nix_hooks = {h["id"]: normalize_nix_hook(h) for r in nix["repos"] for h in r["hooks"]}
    my_hooks = {h["id"]: dict(h, entry=" ".join(h["entry"].split()))
                for h in mine["repos"][0]["hooks"]}
    for hid in sorted(set(nix_hooks) | set(my_hooks)):
        if hid not in my_hooks:
            problems.append(f"hook `{hid}` is in the Nix config and NOT in the portable one")
            continue
        if hid not in nix_hooks:
            problems.append(f"hook `{hid}` is in the portable config and NOT in the Nix one")
            continue
        for field in RAW_FIELDS:
            a, b = nix_hooks[hid].get(field), my_hooks[hid].get(field)
            if a != b:
                problems.append(f"hook `{hid}` field `{field}` differs:\n    nix:      {a!r}\n"
                                f"    portable: {b!r}")
    for p in problems:
        print(f"MISMATCH {p}")
    if problems:
        say(f"{len(problems)} difference(s) between nix/pre-commit.nix as git-hooks.nix "
            "renders it and as this script renders it. Fix BUILTINS or the evaluator.")
        return 1
    print(f"OK: {len(my_hooks)} hooks, identical in every field")
    return 0


def _child_env(hook_id: str, tools: list[str]) -> dict:
    env = dict(os.environ)
    # A Visual Studio developer prompt sets VCINSTALLDIR, and rustc (through
    # the `cc` crate's MSVC lookup) then TRUSTS `link.exe` from PATH instead of
    # locating MSVC itself. Git runs every hook under its own sh, which puts
    # Git's usr\bin -- and coreutils' `link.exe` -- first on PATH. The result
    # is every build script failing with "/usr/bin/link: extra operand", which
    # reads like a broken toolchain and is really a hook-only PATH artefact.
    # Without VCINSTALLDIR rustc finds MSVC through the registry, as it does
    # from any plain shell.
    if os.name == "nt" and "cargo" in tools and env.get("VCINSTALLDIR"):
        link = shutil.which("link") or ""
        if "\\usr\\bin\\" in link.lower().replace("/", "\\"):
            say(f"hook `{hook_id}`: {link} (coreutils) shadows MSVC's link.exe on the hook's "
                "PATH; letting rustc locate MSVC itself (VCINSTALLDIR unset for this hook)")
            env.pop("VCINSTALLDIR", None)
            env.pop("VSINSTALLDIR", None)
    return env


def cmd_exec(args: list[str]) -> int:
    if len(args) < 3 or args[1] != "--":
        say("usage: exec <hook-id> -- <argv...>")
        return 2
    hook_id, argv = args[0], args[2:]
    hook = {"id": hook_id, "entry": shlex.join(argv)}
    problems = missing_tools(hook)
    if problems:
        say(f"hook `{hook_id}` CANNOT RUN on this machine, so it FAILS rather than "
            "passing unchecked:")
        for tool, problem in problems:
            say(f"  {problem}")
            say(f"    remedy: {REMEDIES.get(tool, f'install `{tool}` and put it on PATH')}")
        return 1
    prefix, _ = resolve_tool(argv[0])
    try:
        return subprocess.call(prefix + argv[1:], env=_child_env(hook_id, tools_for(hook)))
    except OSError as e:
        say(f"hook `{hook_id}`: could not start {prefix[0]}: {e}")
        return 1


def _pre_commit_version() -> str | None:
    try:
        import pre_commit.constants as c  # type: ignore

        return c.VERSION
    except Exception:
        return None


def cmd_hook(args: list[str]) -> int:
    if len(args) < 3 or args[1] != "--hook-dir":
        say("usage: hook <hook-type> --hook-dir DIR -- ARGS")
        return 2
    hook_type, hook_dir = args[0], args[2]
    rest = args[4:] if len(args) > 3 and args[3] == "--" else args[3:]
    version = _pre_commit_version()
    if version is None:
        say(f"the pre-commit framework is not installed for {sys.executable}, so the "
            f"{hook_type} checks CANNOT RUN and the {hook_type} FAILS.")
        say(f"  remedy: {PIP_REMEDY}")
        return 1
    try:
        config = runtime_config(canonical_config())
    except NixSubsetError as e:
        say(f"nix/pre-commit.nix could not be rendered without Nix: {e}")
        say("  The checks it declares cannot run, so this fails rather than skipping them.")
        return 1
    hooks = config["repos"][0]["hooks"]
    staged = [h["id"] for h in hooks if hook_type in h["stages"]]
    note = "" if version == PRE_COMMIT_VERSION else f" (Nix pins {PRE_COMMIT_VERSION})"
    say(f"portable layer: {len(staged)} {hook_type} hook(s) from nix/pre-commit.nix, "
        f"pre-commit {version}{note}, {sys.executable}")
    # The config goes in this worktree's git dir, not the system temp dir:
    # pre-commit takes a relpath of it, and on Windows that raises when the temp
    # dir (C:) and the checkout are on different drives.
    git_dir = subprocess.run(["git", "rev-parse", "--absolute-git-dir"], check=True,
                             capture_output=True, text=True).stdout.strip()
    fd, path = tempfile.mkstemp(prefix="codetracer-pre-commit-", suffix=".json", dir=git_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2)
        env = dict(os.environ)
        env.pop("PRE_COMMIT_RUNNING_LEGACY", None)
        return subprocess.call(
            [sys.executable, "-m", "pre_commit", "hook-impl", f"--config={path}",
             f"--hook-type={hook_type}", "--hook-dir", hook_dir, "--", *rest],
            env=env,
        )
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def cmd_doctor(args: list[str]) -> int:
    version = _pre_commit_version()
    print(f"pre-commit framework: {version or 'MISSING'}"
          + ("" if version else f"   remedy: {PIP_REMEDY}"))
    rc = 0 if version else 1
    for hook in canonical_config()["repos"][0]["hooks"]:
        problems = missing_tools(hook)
        state = "ready" if not problems else "WILL FAIL"
        print(f"{hook['id']:26} {','.join(hook['stages']):32} {state}")
        for tool, problem in problems:
            rc = 1
            print(f"    {problem}\n      remedy: {REMEDIES.get(tool, 'install ' + tool)}")
    return rc


def main(argv: list[str]) -> int:
    commands = {
        "generate": cmd_generate,
        "compare": cmd_compare,
        "exec": cmd_exec,
        "hook": cmd_hook,
        "doctor": cmd_doctor,
    }
    if not argv or argv[0] not in commands:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return commands[argv[0]](argv[1:])
    except NixSubsetError as e:
        say(f"nix/pre-commit.nix: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
