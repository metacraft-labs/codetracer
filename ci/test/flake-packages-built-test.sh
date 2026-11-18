#!/usr/bin/env bash
# ci/test/flake-packages-built-test.sh -- every package this flake exports is
# built by some CI job, or is a named exception.
#
# #codetracer-tui stopped compiling (its imports reached runquota, and the
# package set no RUNQUOTA_SRC) and nothing noticed, because no job built it.
# So every flake package must be one of:
#   * BUILT: a workflow, or a script a workflow runs, has an uncommented
#     `nix build ...#<name>` (a command continued with `\` read as one line);
#   * an INPUT of something built: its derivation is in the closure of a built
#     package or of a dev shell a job enters (`nix develop .#<shell>`, or a
#     bare `nix develop` for `default`);
#   * an EXCEPTION listed below with the reason.
# A new package that is none of these fails, as does an exception that is in
# fact built (the list must not outlive its reasons). Negative control: with
# cache-push's build of codetracer-tui-component taken out, the checker must
# name codetracer-tui-component and codetracer-tui. Run by ci/lint/nix.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

# name|reason
exceptions=(
	"codetracer-appimage|flake package not shipped through CI: AppImages are built by appimage-scripts/ (release.yml), and no release doc or script references the package"
	"codetracer-dependency-paths|an empty all-paths.json placeholder; nothing builds or ships it"
	"console|the REPL console; its source, src/repl/repl.nim, no longer exists, so it cannot build"
	"chromedriver-102|a pinned chromedriver for manual browser testing; referenced only commented out (nix/shells/armShell.nix)"
	"darwin-lzma-native-clang|a macOS-only build helper: node-modules-derivation takes it only when stdenv.isDarwin"
	"darwin-lzma-native-cxx|as darwin-lzma-native-clang"
	"darwin-lzma-native-sed|as darwin-lzma-native-clang"
	"nim-1_6|an alternative Nim for testing against older compilers; CodeTracer builds with nim-codetracer"
	"nim-2_0|as nim-1_6"
	"rust-1_75|an alternative Rust for testing against other compilers; CodeTracer builds with the pinned toolchain"
	"rust-1_80|as rust-1_75"
	"rust-nightly|as rust-1_75"
	"rust-stable|as rust-1_75"
	"trace-writer-ffi|the trace writer's C FFI library, exported for Go (cgo) and other C callers; nothing in this repository builds against it"
)

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

uncommented() { grep -vE '^[[:space:]]*#' "$@"; }
mapfile -t builders < <(
	ls .github/workflows/*.yml
	uncommented .github/workflows/*.yml | grep -oE '(ci|scripts)/[A-Za-z0-9_./-]+\.sh' | sort -u |
		while read -r s; do [ -f "$s" ] && echo "$s"; done
)
# Every builder's uncommented text, continued lines joined, one file.
for f in "${builders[@]}"; do
	uncommented "$f" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' | sed "s|^|${f}: |"
done >"$work/builders.txt"

# Every package's derivation (null where it does not evaluate here), and the
# dev shells' input derivations.
nix eval --json ".?submodules=1#packages.${system}" --apply \
	'ps: builtins.mapAttrs (n: p: let r = builtins.tryEval p.drvPath; in if r.success then r.value else null) ps' \
	>"$work/packages.json"
nix eval --json ".?submodules=1#devShells.${system}" --apply \
	'ss: builtins.mapAttrs (n: s: let r = builtins.tryEval s.inputDerivation.drvPath; in if r.success then r.value else null) ss' \
	>"$work/shells.json"
printf '%s\n' "${exceptions[@]}" >"$work/exceptions.txt"

# classify BUILDERS-FILE: one line per problem on stdout; the report on stderr.
classify() {
	python3 -I -B - "$1" "$work/packages.json" "$work/shells.json" "$work/exceptions.txt" <<'PY'
import json, re, subprocess, sys
builders, packages, shells, exceptions = sys.argv[1:5]
text = open(builders).read()
packages = json.load(open(packages))
shells = json.load(open(shells))
exc = dict(line.rstrip("\n").split("|", 1) for line in open(exceptions) if line.strip())

def built(kind, name):
    pat = r"nix build[^\n#]*#(%s\.[A-Za-z0-9_-]+\.)?%s(['\" ^.]|$)" % (kind, re.escape(name))
    for line in text.splitlines():
        if re.search(pat, line):
            return line.split(":", 1)[0]
    return None

roots, problems = {}, []
for name, drv in packages.items():
    where = built("packages", name)
    if where and drv:
        roots[name] = (drv, where)
# A dev shell is realised by any `nix develop` of it: `nix develop .#ci`, or a
# bare `nix develop` (no `#`) for `default`.
def entered(name):
    if name == "default":
        pat = r"nix develop(?![^\n]*#)"
    else:
        pat = r"nix develop[^\n]*#(devShells\.[A-Za-z0-9_-]+\.)?%s(['\" ]|$)" % re.escape(name)
    for line in text.splitlines():
        if re.search(pat, line):
            return line.split(":", 1)[0]
    return None

for name, drv in shells.items():
    where = built("devShells", name) or entered(name)
    if where and drv:
        roots["devShells." + name] = (drv, where)
closure = {}
for root, (drv, where) in roots.items():
    for path in subprocess.check_output(["nix-store", "-qR", drv], text=True).split():
        closure.setdefault(path, root)
for name, drv in sorted(packages.items()):
    if name in roots:
        state = f"built by {roots[name][1]}"
    elif drv and drv in closure:
        state = f"built as an input of {closure[drv]}"
    elif name in exc:
        print(f"  exception {name}: {exc[name]}", file=sys.stderr)
        continue
    else:
        problems.append(f"{name}: no job builds it, nor anything that takes it as an input, and it is not an exception")
        continue
    if name in exc:
        problems.append(f"{name} is listed as an exception but is {state}: drop the exception")
    print(f"  ok   {name}: {state}", file=sys.stderr)
for name in exc:
    if name not in packages:
        problems.append(f"exception {name} names no flake package")
for p in problems:
    print(p)
PY
}

failures=0
problems="$(classify "$work/builders.txt")"
if [ -n "$problems" ]; then
	echo "  FAIL flake packages no CI job builds:"
	while IFS= read -r line; do echo "         $line"; done <<<"$problems"
	failures=$((failures + 1))
else
	echo "  ok   every flake package is built by a job, built as an input of one, or a named exception"
fi

# Negative control: without cache-push's build of the TUI component.
grep -v '#codetracer-tui-component' "$work/builders.txt" >"$work/builders-without-tui.txt"
control="$(classify "$work/builders-without-tui.txt" 2>/dev/null)"
if grep -q '^codetracer-tui-component:' <<<"$control" && grep -q '^codetracer-tui:' <<<"$control"; then
	echo "  ok   negative control: without the TUI component's build, both TUI packages are named"
else
	echo "  FAIL negative control: without the TUI component's build the checker said: ${control:-nothing}"
	failures=$((failures + 1))
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
