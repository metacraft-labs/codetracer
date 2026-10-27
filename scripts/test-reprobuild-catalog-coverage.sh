#!/usr/bin/env bash
# =============================================================================
# Reprobuild catalog coverage — every package name `repro.nim`'s `uses:` list
# declares must resolve against the `reprobuild-packages` catalog this flake
# PINS, using the same rule reprobuild uses to resolve it.
#
# ## The defect this exists to catch
#
# `nix/shells/ci-base.nix` exports
#
#     REPROBUILD_PACKAGES_ROOT=${inputs.reprobuild-packages}
#
# and when that variable is set reprobuild looks in NO other catalog: not a
# `../reprobuild-packages` workspace sibling, not anywhere else. That is
# deliberate (one catalog every lane of the shell agrees on), and it means the
# pinned catalog has to define every package the recipe names that the
# engine's bundled stdlib no longer carries.
#
# It did not. `repro.nim` has declared `uses: "shellcheck >=0"` since
# `e79de25ee` (2026-07-08). `ba49811db` (2026-09-30) introduced the flake input
# at reprobuild-packages `9d9176bff5c5` (2026-09-29), whose
# `packages/interfaces/` held busybox, llvm, patchelf and sqlite3 — and
# `shellcheck` entered the catalog in `5cb3f71026c5` the NEXT day. reprobuild
# lists `shellcheck` in `MovedToReprobuildPackages`, so inside the project's own
# `nix develop` the recipe did not compile:
#
#     repro.nim(457): uses: "shellcheck >=0" names `shellcheck`, which is no
#       longer bundled with reprobuild's stdlib: it is defined by the
#       reprobuild-packages catalog (packages/interfaces/shellcheck/repro.nim),
#       and no reachable catalog defines it.
#       - /nix/store/kj2cl0vv6r7i9kxcpgpb8zxm56g5g551-source
#         ($REPROBUILD_PACKAGES_ROOT): checkout present, but it has no
#         packages/interfaces/shellcheck/repro.nim; it is set, so no other
#         location was consulted
#
# — every `repro`-driven target, including the `just build-once` remedy that
# `ci/lib/build-freshness.sh` prints, was dead in the shell meant to run it.
# (codetracer-pm issues/2026-10-13-the-codetracer-dev-shell-pins-a-package-
# catalog-that-predates-shellcheck-and-suppresses-the-sibling-that-has-it.md.)
# The pin was later moved to `4e2fd1dcabf8`, which has it; nothing stopped the
# two drifting apart again. This does.
#
# ## The rule — reprobuild's own, read out of the reprobuild this flake pins
#
# For each name in the `uses:` block of `package codeTracer:` — and in its
# `buildDeps:`, `nativeBuildDeps:` and `runtimeDeps:` blocks, should it grow
# any, since reprobuild resolves and fails all four the same way — and in
# EVERY `when` branch, because this is a static check and a name only Linux or
# Windows reaches breaks those hosts just the same — the name resolves when,
# in order:
#
#   1. the pinned catalog has `packages/interfaces/<name>/repro.nim`
#      (reprobuild `reprobuildPackagesSearch`, the catalog probe);
#   2. else it is one of reprobuild's `BundledStdlibSelectors` AND NOT one of
#      its `MovedToReprobuildPackages` (the stdlib still defines it);
#   3. else it is a workspace producer — a `deps` entry of `repro.lock` — which
#      the engine's moved-name diagnostic exempts (`workspaceProducerModule`);
#
# and is UNRESOLVED otherwise. A moved name the catalog lacks is unresolved
# even though reprobuild may still ship a stdlib module of that name: those are
# import STUBS (`MovedPackageImportStubs`) that declare no package and that a
# `uses:` line never reaches.
#
# Both lists are parsed from the pinned reprobuild source — `macros_a.nim` and
# `reprobuild_packages_catalog.nim` under `libs/repro_project_dsl/src/` — and
# never copied here, so the next name reprobuild moves out of its stdlib is
# checked the day this flake's reprobuild pin crosses that move.
#
# It also asserts that `flake.lock`'s `reprobuild-packages` revision equals
# `repro.lock`'s `reprobuild-packages` dep revision. They are two pins of the
# one catalog (the dev shell reads the first, a lock-driven `repro` the
# second), and a check that validated one while the other drifted would be
# validating the wrong catalog half the time.
#
# ## Why this is a static check and not "just run repro tasks"
#
# Running the recipe proves it for ONE platform, after a dev shell that takes
# minutes to enter. This reads three text files and lists one directory: no
# toolchain, under a second, every platform branch at once. Locating the two
# pinned trees costs one `nix eval` each, answered from the eval cache.
#
# ## Inputs, and loud skips
#
#   CT_CATALOG_COVERAGE_REPO_ROOT       the codetracer checkout (default: this
#                                       script's repository)
#   CT_CATALOG_COVERAGE_REPROBUILD_SRC  reprobuild source tree (default: the
#                                       flake's `reprobuild` input, via nix)
#   CT_CATALOG_COVERAGE_CATALOG_ROOT    reprobuild-packages tree (default: the
#                                       flake's `reprobuild-packages` input)
#
# The overrides exist so ci/test/reprobuild-catalog-coverage-test.sh can drive
# the real script over fixtures with no nix, and so a reader can point it at
# any catalog revision (`nix eval --raw --impure --expr '(builtins.fetchTree
# { type = "github"; owner = "metacraft-labs"; repo = "reprobuild-packages";
# rev = "<sha>"; }).outPath'`).
#
# When a root is NOT overridden and `nix` is not on PATH, the script prints a
# SKIP naming what it could not do and exits 0; it never reports a pass for a
# comparison it did not make. CT_CATALOG_COVERAGE_STRICT=1 turns that skip into
# a failure, which is what the lint lane sets. A `nix eval` that runs and
# FAILS is never a skip: the flake inputs exist, and not being able to locate
# them is a failure that names itself.
#
# ## Wrong accusations are worse than no check
#
# Every extraction that comes back implausible — no `uses:` names, no bundled
# selectors, no `MovedToReprobuildPackages`, a catalog root that is missing or
# has no `packages/interfaces`, a `uses:` line this parser does not recognise —
# fails as THAT, before any name is judged. Otherwise a parser that rotted
# would report the whole recipe unresolved and send the reader to move a pin
# that is correct. The contract suite asserts both halves for every path: the
# right diagnostic, and the absence of the wrong one.
# =============================================================================
# The diagnostics this script prints quote Nim and TOML source in markdown code spans,
# so single-quoted strings full of literal backticks are the norm here, and
# shfmt -s rewrites the escaped double-quoted form into exactly that.
# shellcheck disable=SC2016
set -uo pipefail

# `${BASH_SOURCE[0]%/*}` rather than `dirname`, so that the python3-absent case
# below can be exercised with an empty PATH and still reach its own diagnostic.
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
REPO_ROOT="${CT_CATALOG_COVERAGE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STRICT="${CT_CATALOG_COVERAGE_STRICT:-0}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# A skip is a statement that the check did NOT run, and says why.
skip() {
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_CATALOG_COVERAGE_STRICT=1): $*" >&2
		exit 1
	fi
	echo "SKIP: $*" >&2
	echo "SKIP: reprobuild catalog coverage was NOT verified by this run." >&2
	exit 0
}

# The lock files are JSON and TOML and repro.nim is Nim; all three are read by
# a real program, never grepped. A missing python3 is a failure that names
# itself and makes no claim about any pin.
command -v python3 >/dev/null 2>&1 || fail \
	'python3 is required to parse repro.nim, flake.lock and repro.lock, and is not on PATH. Run inside a dev shell (`nix develop .#lint --command just test-reprobuild-catalog-coverage`). NOTHING about the catalog pin has been established by this run.'

[ -d "$REPO_ROOT" ] || fail "repo root $REPO_ROOT does not exist."

# Resolve one flake input to its store path. Only consulted when the matching
# override is unset.
flake_input_path() {
	local input="$1" out rc
	command -v nix >/dev/null 2>&1 ||
		skip "\`nix\` is not on PATH, so the flake's '$input' input cannot be located. Set CT_CATALOG_COVERAGE_REPROBUILD_SRC / CT_CATALOG_COVERAGE_CATALOG_ROOT to the trees to check, or run where nix is available."
	# The path is spliced into a Nix string literal; refuse anything that could
	# end or interpolate it rather than escape it.
	case "$REPO_ROOT" in
	*'"'* | *"\\"* | *'$'*) fail "repo root '$REPO_ROOT' contains a character this script will not splice into a Nix expression." ;;
	esac
	# stdout carries only the path; stderr is kept apart and shown on failure.
	# Merging them made the path unreadable whenever nix had anything else to
	# say -- a fresh runner's "unpacking ... into the Git cache", an unknown
	# setting warning, an auto-GC's progress -- with nix still exiting 0.
	local err
	err="$(mktemp)"
	out="$(nix eval --raw --impure --expr \
		"(builtins.getFlake \"$REPO_ROOT\").inputs.\"$input\".outPath" 2>"$err")"
	rc=$?
	if [ "$rc" -ne 0 ] || [ ! -d "$out" ]; then
		local diag
		diag="$(cat "$err")"
		rm -f "$err"
		fail "could not locate the flake's '$input' input (nix eval exited $rc). This is a failure to READ the pin, NOT a statement that the catalog lacks anything. nix stdout:
$out
nix stderr:
$diag"
	fi
	rm -f "$err"
	printf '%s\n' "$out"
}

# `|| exit 1` is load-bearing: `flake_input_path` runs in a command
# substitution, so its `fail`/`skip` leave only that subshell. A non-strict
# `skip` exits that subshell 0 with the SKIP already on stderr and nothing on
# stdout, so the empty result is what tells the parent to stop — with 0, since
# the skip has been reported. Without these two lines the script would carry
# on with an empty root and report it "missing", a false accusation printed
# directly beneath the honest skip.
REPROBUILD_SRC="${CT_CATALOG_COVERAGE_REPROBUILD_SRC:-}"
REPROBUILD_SRC_ORIGIN="CT_CATALOG_COVERAGE_REPROBUILD_SRC"
if [ -z "$REPROBUILD_SRC" ]; then
	REPROBUILD_SRC="$(flake_input_path reprobuild)" || exit 1
	[ -n "$REPROBUILD_SRC" ] || exit 0
	REPROBUILD_SRC_ORIGIN="flake input 'reprobuild'"
fi
CATALOG_ROOT="${CT_CATALOG_COVERAGE_CATALOG_ROOT:-}"
CATALOG_ORIGIN="CT_CATALOG_COVERAGE_CATALOG_ROOT"
if [ -z "$CATALOG_ROOT" ]; then
	CATALOG_ROOT="$(flake_input_path reprobuild-packages)" || exit 1
	[ -n "$CATALOG_ROOT" ] || exit 0
	CATALOG_ORIGIN="flake input 'reprobuild-packages'"
fi

# Everything below is one python program: parse, then judge. Exit 2 means an
# extraction failed and NO name was judged; exit 1 is a verdict; 0 is a pass.
python3 - "$REPO_ROOT" "$REPROBUILD_SRC" "$REPROBUILD_SRC_ORIGIN" \
	"$CATALOG_ROOT" "$CATALOG_ORIGIN" <<'PY'
import json
import os
import re
import sys

repo_root, rb_src, rb_origin, catalog_root, catalog_origin = sys.argv[1:6]

PACKAGE_NAME = "codeTracer"
CATALOG_INPUT = "reprobuild-packages"
DSL_SRC = os.path.join("libs", "repro_project_dsl", "src")


def extraction_failure(msg):
    """Stop before judging any name. The wording says so on purpose."""
    sys.stderr.write(
        "FAIL (extraction): " + msg + "\n"
        "FAIL (extraction): no uses: name was judged; this is NOT a statement "
        "that the catalog pin is wrong. Fix the input, or update "
        "scripts/test-reprobuild-catalog-coverage.sh to match what changed.\n")
    sys.exit(2)


def strip_comment(line):
    """Drop a Nim `#` comment, ignoring `#` inside a "..." literal.

    Returns (code, opens_block_comment). `#[ ... ]#` block comments are only
    recognised so they can be refused: none appear in a `uses:` block today,
    and silently mis-reading one is the failure this script exists to avoid.
    """
    in_str = False
    i = 0
    while i < len(line):
        ch = line[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "#":
            return line[:i], line[i:i + 2] == "#["
        i += 1
    return line, False


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


STRING_LIT = re.compile(r'"((?:[^"\\]|\\.)*)"')


def literals_in(code):
    return STRING_LIT.findall(code)


# --- repro.nim: the package's uses: block, every branch ---------------------

# The four package-level dependency lists reprobuild resolves by name, keyed by
# Nim's `normalize` of the block name (lowercase, underscores dropped), which
# is how reprobuild's `parsePackageDef` recognises them (macros_a.nim,
# `calleeName(stmt).normalize == ...`). `buildDeps:` is the canonical spelling
# of `uses:` and fills the same list; `nativeBuildDeps:` and `runtimeDeps:` are
# separate lists, but `usesImportCode` consults the catalog for every one of
# them and the moved-name diagnostic (`unresolvedMovedPackageDiagnostic`)
# fails the compile for any of them. Reading only `uses:` would pass a recipe
# that names a moved package in one of the other three and does not compile.
DEP_BLOCKS = {
    "uses": "uses",
    "builddeps": "buildDeps",
    "nativebuilddeps": "nativeBuildDeps",
    "runtimedeps": "runtimeDeps",
}
DEP_BLOCK_HEAD = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:")


def dep_block_name(stripped):
    """The canonical list name when `stripped` opens a dependency block."""
    m = DEP_BLOCK_HEAD.match(stripped)
    if not m:
        return None
    return DEP_BLOCKS.get(m.group(1).replace("_", "").lower())


def extract_uses(path):
    try:
        with open(path) as handle:
            lines = handle.read().split("\n")
    except OSError as exc:
        extraction_failure("cannot read %s: %s" % (path, exc))
    pkg_re = re.compile(r"^(\s*)package\s+" + PACKAGE_NAME + r"\s*:\s*$")
    start = None
    for idx, raw in enumerate(lines):
        code, _ = strip_comment(raw)
        m = pkg_re.match(code.rstrip())
        if m:
            start, pkg_indent = idx, len(m.group(1))
            break
    if start is None:
        extraction_failure(
            "%s has no `package %s:` block." % (path, PACKAGE_NAME))

    # The package body: the lines after it that are indented deeper. Its
    # child level is the indent of its first code line.
    child_indent = None
    uses = []  # (name, raw literal, line number, branch condition, list)
    idx = start + 1
    while idx < len(lines):
        code, block = strip_comment(lines[idx])
        if block:
            extraction_failure(
                "%s:%d opens a `#[` block comment inside `package %s:`, which "
                "this parser does not read." % (path, idx + 1, PACKAGE_NAME))
        if not code.strip():
            idx += 1
            continue
        ind = indent_of(code)
        if ind <= pkg_indent:
            break
        if child_indent is None:
            child_indent = ind
        stripped = code.strip()
        list_name = dep_block_name(stripped) if ind == child_indent else None
        if list_name:
            idx = read_uses_block(path, lines, idx, child_indent, uses,
                                  list_name)
            continue
        idx += 1
    if not uses:
        extraction_failure(
            "parsed ZERO names from the `uses:` block of `package %s:` in %s. "
            "A recipe that uses nothing is implausible; the parser has lost "
            "the block." % (PACKAGE_NAME, path))
    return uses


def read_uses_block(path, lines, idx, child_indent, uses, list_name):
    """Read one dependency section (`uses:`, `buildDeps:`, `nativeBuildDeps:`
    or `runtimeDeps:`) starting at line `idx`; return the next idx."""
    branch = []  # stack of (indent, condition)

    def take(code, lineno, ind):
        lits = literals_in(code)
        if not lits:
            return False
        while branch and branch[-1][0] >= ind:
            branch.pop()
        cond = " and ".join("(%s)" % c for _, c in branch) or "all platforms"
        for lit in lits:
            name = lit.split()[0] if lit.split() else ""
            if not name:
                extraction_failure(
                    "%s:%d has an empty uses: literal." % (path, lineno))
            uses.append((name, lit, lineno, cond, list_name))
        return True

    head, _ = strip_comment(lines[idx])
    inline = head.split(":", 1)[1].strip()
    if inline and not take(inline, idx + 1, child_indent + 1):
        extraction_failure(
            "%s:%d: `%s:` is followed by `%s`, which is not a string "
            "literal this parser reads." % (path, idx + 1, list_name, inline))
    idx += 1
    while idx < len(lines):
        code, block = strip_comment(lines[idx])
        if block:
            extraction_failure(
                "%s:%d opens a `#[` block comment inside `%s:`." %
                (path, idx + 1, list_name))
        if not code.strip():
            idx += 1
            continue
        ind = indent_of(code)
        if ind <= child_indent:
            return idx
        stripped = code.strip()
        m = re.match(r"^(when|elif)\s+(.*):$", stripped)
        if m or stripped == "else:":
            # A branch at this indent closes every branch at or below it; the
            # last one closed is the `when` an `else:` negates. The condition
            # is kept only to LABEL a failure with the platform it hits.
            closed = None
            while branch and branch[-1][0] >= ind:
                closed = branch.pop()
            if m:
                cond = m.group(2).strip()
            else:
                cond = "not (%s)" % closed[1] if closed else "else"
            branch.append((ind, cond))
        elif re.fullmatch(r'(\s*"(?:[^"\\]|\\.)*"\s*,?)+', stripped):
            take(code, idx + 1, ind)
        else:
            # An identifier, a `&` expression, a macro call... — any of them
            # could carry a name this script would otherwise silently skip.
            extraction_failure(
                "%s:%d: `%s` inside `%s:` is neither a string literal nor a "
                "`when`/`elif`/`else` branch, so the names it contributes "
                "cannot be read statically." %
                (path, idx + 1, stripped, list_name))
        idx += 1
    return idx


# --- reprobuild source: the two lists ---------------------------------------

# Where each list lives. A list is accepted in either of the shapes reprobuild
# has shipped, so the guard can be pointed at an older pin (the issue was
# reproduced against reprobuild 064daf5b = v0.2.10, the `repro` the dev shell
# carried when it was found) without being edited:
#   * `const BundledStdlibSelectors* = [...]` in macros_a.nim — current, e.g.
#     reprobuild 1a3779fc, the pin at codetracer 845e390fb2;
#   * `proc isBundledStdlibSelector(...) = selector in [...]`, nested in
#     `usesImportCode` — v0.2.10 and earlier.
# A tree carrying neither is an extraction failure, never "nothing bundled".
LIST_SHAPES = {
    "BundledStdlibSelectors": [
        r"^\s*const\s+BundledStdlibSelectors\*?\s*(:[^=]*)?=",
        r"^\s*proc\s+isBundledStdlibSelector\*?\([^)]*\)\s*:\s*bool\s*="
        r"\s*\n(?:\s*#[^\n]*\n)*\s*selector\s+in\s*",
    ],
    "MovedToReprobuildPackages": [
        r"^\s*const\s+MovedToReprobuildPackages\*?\s*(:[^=]*)?=",
    ],
}


def find_const(src_root, const_name):
    """Locate list `const_name` in the DSL sources; return (path, text, pos)."""
    base = os.path.join(src_root, DSL_SRC)
    if not os.path.isdir(base):
        extraction_failure(
            "reprobuild source %s (%s) has no %s; it is not a reprobuild "
            "tree, or the DSL moved." % (src_root, rb_origin, DSL_SRC))
    hits = []
    for dirpath, _, files in os.walk(base):
        for fname in sorted(files):
            if not fname.endswith(".nim"):
                continue
            fpath = os.path.join(dirpath, fname)
            with open(fpath, errors="replace") as handle:
                text = handle.read()
            for shape in LIST_SHAPES[const_name]:
                m = re.search(shape, text, re.M)
                if m:
                    hits.append((fpath, text, m.end()))
                    break
    if not hits:
        extraction_failure(
            "no definition of `%s` in %s (%s). reprobuild renamed or removed "
            "it; "
            "re-derive the resolution rule from its sources." %
            (const_name, base, rb_origin))
    if len(hits) > 1:
        extraction_failure(
            "`const %s` is defined in %d files (%s); refusing to guess which "
            "one the engine uses." %
            (const_name, len(hits), ", ".join(h[0] for h in hits)))
    return hits[0]


def bracket_literals(path, text, pos, const_name, allow_empty):
    """String literals between the first `[` after `pos` and its `]`."""
    open_at = text.find("[", pos)
    if open_at < 0:
        extraction_failure("`const %s` in %s has no `[`." % (const_name, path))
    names = []
    body_code = []
    depth = 0
    for raw in text[open_at:].split("\n"):
        code, _ = strip_comment(raw)
        done = False
        for i, ch in enumerate(code):
            # Brackets inside literals do not occur in these lists; a
            # selector containing one would be refused by the literal parse.
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    if code[i + 1:].strip():
                        # `@[...] & more`: names this parse cannot see.
                        extraction_failure(
                            "`const %s` in %s continues past its closing "
                            "`]` (`%s`); it can no longer be read "
                            "statically." %
                            (const_name, path, code[i + 1:].strip()))
                    code = code[:i]
                    done = True
                    break
        body_code.append(code)
        if done:
            break
    else:
        extraction_failure(
            "`const %s` in %s: unterminated `[`." % (const_name, path))
    body = "\n".join(body_code)
    names = literals_in(body)
    leftover = STRING_LIT.sub("", body).replace("@", "").replace("[", "")
    if re.search(r"[A-Za-z0-9_]", leftover):
        extraction_failure(
            "`const %s` in %s contains something other than string literals "
            "(`%s`); it can no longer be read statically." %
            (const_name, path, " ".join(leftover.split())[:120]))
    if not names and not allow_empty:
        extraction_failure(
            "parsed ZERO names from `const %s` in %s. The stdlib bundles "
            "dozens of selectors; an empty answer means the parser lost the "
            "list, and judging against it would report every bundled name "
            "unresolved." % (const_name, path))
    return names


bundled_path, text, pos = find_const(rb_src, "BundledStdlibSelectors")
bundled = set(bracket_literals(bundled_path, text, pos,
                               "BundledStdlibSelectors", allow_empty=False))
moved_path, text, pos = find_const(rb_src, "MovedToReprobuildPackages")
moved = set(bracket_literals(moved_path, text, pos,
                             "MovedToReprobuildPackages", allow_empty=True))


# --- the catalog tree --------------------------------------------------------

interfaces = os.path.join(catalog_root, "packages", "interfaces")
if not os.path.isdir(catalog_root):
    extraction_failure(
        "the catalog root %s (%s) does not exist." %
        (catalog_root, catalog_origin))
if not os.path.isdir(interfaces) or not os.listdir(interfaces):
    extraction_failure(
        "the catalog root %s (%s) has no packages/interfaces/ entries; it is "
        "not a reprobuild-packages tree, or the catalog layout changed "
        "(reprobuild `reprobuildPackagesSearch` reads "
        "packages/interfaces/<name>/repro.nim)." %
        (catalog_root, catalog_origin))


# --- the two pins of the catalog --------------------------------------------

def flake_lock_rev(path, name):
    try:
        with open(path) as handle:
            nodes = json.load(handle)["nodes"]
    except (OSError, ValueError, KeyError) as exc:
        extraction_failure("cannot read %s as a flake.lock: %s" % (path, exc))
    edge = nodes.get("root", {}).get("inputs", {}).get(name)
    if edge is None:
        extraction_failure(
            "%s's root has no input named '%s'. If the input was renamed, "
            "update this check." % (path, name))
    if isinstance(edge, list):
        extraction_failure(
            "%s's '%s' input is a follows path (%s); this check expects the "
            "catalog to be pinned directly. Update it." %
            (path, name, "/".join(edge)))
    rev = nodes.get(edge, {}).get("locked", {}).get("rev", "")
    if not rev:
        extraction_failure("%s node '%s' has no locked rev." % (path, edge))
    return rev


def repro_lock_deps(path):
    """name -> revision for repro.lock's `deps = [ { ... }, ... ]`.

    repro.lock is TOML, but its `deps` value is one line of flat inline tables
    whose values are plain strings, and the python in the dev shells is not
    guaranteed to carry `tomllib` (3.11+); the host python measured here was
    3.9.6. So the line is parsed by shape, and a shape it does not match is an
    extraction failure rather than an empty answer.
    """
    try:
        with open(path) as handle:
            text = handle.read()
    except OSError as exc:
        extraction_failure("cannot read %s: %s" % (path, exc))
    m = re.search(r"^deps\s*=\s*\[(.*)\]\s*$", text, re.M)
    if not m:
        extraction_failure("%s has no `deps = [...]` line." % path)
    deps = {}
    for entry in re.findall(r"\{([^{}]*)\}", m.group(1)):
        fields = dict(re.findall(r'(\w+)\s*=\s*"((?:[^"\\]|\\.)*)"', entry))
        if "name" in fields:
            deps[fields["name"]] = fields.get("revision", "")
    if not deps:
        extraction_failure(
            "parsed ZERO deps from %s; every workspace producer would then be "
            "reported unresolved." % path)
    return deps


flake_rev = flake_lock_rev(os.path.join(repo_root, "flake.lock"),
                           CATALOG_INPUT)
deps = repro_lock_deps(os.path.join(repo_root, "repro.lock"))
uses = extract_uses(os.path.join(repo_root, "repro.nim"))

failures = []

lock_rev = deps.get(CATALOG_INPUT)
if lock_rev is None:
    failures.append(
        "repro.lock has no `%s` dep, so a lock-driven repro has no catalog "
        "pin to agree with flake.lock's %s." % (CATALOG_INPUT, flake_rev))
elif lock_rev != flake_rev:
    failures.append(
        "the two pins of the catalog disagree:\n"
        "    flake.lock  reprobuild-packages rev      = %s\n"
        "    repro.lock  reprobuild-packages revision = %s\n"
        "  The dev shell exports the first as REPROBUILD_PACKAGES_ROOT; a\n"
        "  lock-driven repro resolves the second. Move them together:\n"
        "    repro lock update reprobuild-packages --to <rev>\n"
        "  and the `reprobuild-packages` url in flake.nix (then\n"
        "  `nix flake lock`)." % (flake_rev, lock_rev or "<empty>"))


def bare(name):
    # reprobuild `isBareCatalogSelector`: a path-like selector is never
    # looked up in the catalog.
    return name and not any(c in name for c in "/\\.:")


resolved = {"catalog": [], "bundled": [], "workspace": []}
seen = set()
for name, lit, lineno, cond, list_name in uses:
    if bare(name) and os.path.isfile(
            os.path.join(interfaces, name, "repro.nim")):
        where = "catalog"
    elif name in bundled and name not in moved:
        where = "bundled"
    elif name in deps:
        where = "workspace"
    else:
        why = []
        if name in moved:
            why.append(
                "reprobuild lists it in MovedToReprobuildPackages (%s): the "
                "stdlib no longer defines it, and any stdlib module of that "
                "name is an import stub, not a package" % moved_path)
        else:
            why.append("it is not one of reprobuild's BundledStdlibSelectors "
                       "(%s)" % bundled_path)
        why.append("it is not a repro.lock dep (workspace producer)")
        failures.append(
            "repro.nim:%d `%s: \"%s\"` [%s] names `%s`, which does not "
            "resolve:\n"
            "  - the catalog has no packages/interfaces/%s/repro.nim\n"
            "      looked in: %s (%s; flake.lock pins reprobuild-packages "
            "@ %s)\n"
            "  - %s\n"
            "  - %s\n"
            "  The dev shell sets REPROBUILD_PACKAGES_ROOT to that catalog, "
            "so reprobuild consults no other: the recipe does not compile "
            "there.\n"
            "  Remedy: move the `reprobuild-packages` url in flake.nix to a "
            "revision whose packages/interfaces/%s/repro.nim exists (by "
            "REVISION, see the comment there), run `nix flake lock`, and keep "
            "repro.lock in step with `repro lock update reprobuild-packages "
            "--to <rev>`. If `%s` is a typo or not meant to come from the "
            "catalog, fix repro.nim instead." %
            (lineno, list_name, lit, cond, name, name, interfaces,
             catalog_origin, flake_rev, why[0], why[1], name, name))
        continue
    if name not in seen:
        seen.add(name)
        resolved[where].append(name)

print("reprobuild source:  %s (%s)" % (rb_src, rb_origin))
print("catalog:            %s (%s)" % (catalog_root, catalog_origin))
print("catalog pins:       flake.lock %s, repro.lock %s" %
      (flake_rev, lock_rev or "<none>"))
print("lists parsed:       %d bundled selectors, %d moved (%s)" %
      (len(bundled), len(moved), ", ".join(sorted(moved)) or "none"))
for where in ("catalog", "bundled", "workspace"):
    print("resolved, %-9s %s" % (where + ":", ", ".join(resolved[where]) or "-"))

if failures:
    for msg in failures:
        sys.stderr.write("FAIL: " + msg + "\n")
    sys.stderr.write("FAIL: %d problem(s); %d uses: entries checked.\n" %
                     (len(failures), len(uses)))
    sys.exit(1)
print("OK: all %d uses: entries (%d distinct names) resolve against the "
      "pinned catalog." % (len(uses), len(seen)))
PY
