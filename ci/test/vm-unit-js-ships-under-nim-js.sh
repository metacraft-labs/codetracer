#!/usr/bin/env bash
#
# vm-unit-js-ships-under-nim-js.sh — `vm-unit-js` runs the ViewModel suites
# whose subject ships under `nim js`, and only those.
#
# The panes' ViewModels run in the WebAssembly core (`-d:ctWasmPanes`), and the
# JavaScript lane is kept for what still ships compiled by `nim js`: the
# renderer's shell (`ui_js.nim`, the desktop's and the web build's), the main
# process and `ct host` (`index.nim`), the subwindow, the VS Code host and
# panel, and BlockTracer's Embed SDK bundle (`codetracer_embed.nim`, which
# BlockTracer's `client/hydrate/build.sh` compiles with `nim js`).
# `ci/lib/test-lane-files.sh` subtracts the suites whose subject none of those
# bundles compiles (`_TLF_VM_UNIT_JS_NOT_SHIPPED`).
#
# That list is a measurement, so it is held against the thing it measures.
# This script compiles every one of those bundles with `--genDeps:on` and
# reads the modules each one really compiles, then fails in BOTH directions:
#
#   * a suite on the list whose direct project imports reach a bundle's module
#     — it ships now, and the JS lane must run it again;
#   * a suite in `vm-unit-js` whose direct project imports reach NO bundle's
#     module and which has no `when defined(js)` arm — it belongs on the list.
#
# Exempt from the second direction, by contract rather than by measurement:
# the suites that import the identity layer (`viewmodel/identity/`), which
# `ci/test/identity-suites-are-in-a-lane.sh` requires on every backend's lane
# while the JS lane exists (ID1: every product links the verifier); and the
# suites `_tlf_js_only_suites` routes here because they import a JS-only
# standard-library module.
#
# A bundle that does not build fails the script, and so does a module graph
# smaller than 50 of this repository's modules (3 for the subwindow, which is
# small by design): an empty graph would make every suite look unshipped and
# every listed suite look correct.
#
# Usage:  bash ci/test/vm-unit-js-ships-under-nim-js.sh
#         (inside the dev shell, siblings beside the checkout)
# Exit 0 when the list and the lane agree with the graphs, 1 when they do not
# or a bundle failed to build, 2 when a tool is missing.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

for tool in nim python3; do
	command -v "${tool}" >/dev/null || {
		echo "ERROR: ${tool} is not on PATH" >&2
		exit 2
	}
done

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/test-lane-files.sh"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091
source "${repo_root}/ci/lib/nim-cache-root.sh"

work="$(ct_nim_cache_root "${repo_root}")/vm-unit-js-ships"
rm -rf "${work}"
mkdir -p "${work}"

# The bundles, with the defines each product build gives them
# (`repro.nim`'s `CommonNimDefines`, `RendererDefines` and the entries' own).
common=(-d:chronicles_sinks=json -d:chronicles_line_numbers=true
	-d:chronicles_timestamps=UnixTime -d:ssl -d:nimNoLentIterators -d:debug)
failed=0
graph() {
	local name="$1"
	shift
	mkdir -p "${work}/${name}"
	if nim js --hints:off --warnings:off --genDeps:on \
		--nimcache:"${work}/${name}" --out:"${work}/${name}.js" "$@" \
		>"${work}/${name}.log" 2>&1; then
		echo "  built ${name}"
	else
		echo "  [FAILED] ${name} did not build:"
		tail -n 5 "${work}/${name}.log" | sed 's/^/           /'
		failed=1
	fi
}
echo "--- the bundles that ship under nim js ---"
graph desktop -d:chronicles_enabled=off -d:ctRenderer -d:ctWasmPanes src/frontend/ui_js.nim
graph web -d:chronicles_enabled=off -d:ctRenderer -d:ctWeb -d:ctWasmPanes src/frontend/ui_js.nim
graph index "${common[@]}" -d:ctIndex -d:nodejs src/frontend/index.nim
graph server "${common[@]}" -d:ctIndex -d:server -d:nodejs src/frontend/index.nim
graph subwindow -d:chronicles_enabled=off -d:ctRenderer src/frontend/subwindow.nim
graph vscode_host -d:nodejs -d:chronicles_enabled=off src/frontend/entries/vscode_host.nim
graph vscode_panel -d:chronicles_enabled=off src/frontend/entries/vscode_panel.nim
graph embed_sdk -d:chronicles_enabled=off --path:src/frontend/viewmodel --path:src/frontend --path:src \
	src/frontend/viewmodel/codetracer_embed.nim
[ "${failed}" -eq 0 ] || {
	echo "RESULT: FAILED — a bundle did not build"
	exit 1
}

echo "--- the lane and the list ---"
test_lane_files vm-unit-js >"${work}/lane.txt"
test_lane_files vm-unit >"${work}/vm-unit.txt"
printf '%s\n' "${_TLF_VM_UNIT_JS_NOT_SHIPPED[@]}" >"${work}/not-shipped.txt"
_tlf_vm_unit_candidates | _tlf_js_only_suites keep >"${work}/js-only.txt"

python3 - "${repo_root}" "${work}" <<'PY'
import os, re, sys
root, work = sys.argv[1], sys.argv[2]
root = os.path.realpath(root) + "/"
bundles = {}
for name in ["desktop", "web", "index", "server", "subwindow", "vscode_host", "vscode_panel", "embed_sdk"]:
    deps = [f for f in os.listdir(os.path.join(work, name)) if f.endswith(".deps")]
    mods = set()
    for d in deps:
        for line in open(os.path.join(work, name, d)):
            p = os.path.realpath(line.strip())
            if p.startswith(root):
                mods.add(os.path.relpath(p, root))
    bundles[name] = mods
checks = failures = 0
def ok(msg):
    global checks; checks += 1; print("  [OK]    ", msg)
def bad(msg):
    global checks, failures; checks += 1; failures += 1; print("  [FAILED]", msg)
# The subwindow is a small bundle by design (six modules at 2026-11-22);
# every other one compiles at least fifty.
floor = {"subwindow": 3}
for name, mods in bundles.items():
    (ok if len(mods) >= floor.get(name, 50) else bad)(f"{name} compiles {len(mods)} of this repository's modules")
shipped = set().union(*bundles.values())

paths = ["src/frontend/viewmodel", "src/frontend", "src"]
def statements(src):
    out, cur, depth = [], None, 0
    for line in src.split("\n"):
        line = re.sub(r"#.*", "", line)
        if cur is not None:
            cur += " " + line; depth += line.count("[") - line.count("]")
            if depth <= 0 and not cur.rstrip().endswith(","):
                out.append(cur); cur = None
            continue
        if re.match(r"(import|from)\s", line):
            cur, depth = line, line.count("[") - line.count("]")
            if depth <= 0 and not cur.rstrip().endswith(","):
                out.append(cur); cur = None
    return out
def modules(stmt):
    stmt = re.sub(r"\s+", " ", stmt).strip()
    if stmt.startswith("from "):
        return [stmt.split()[1]]
    res = []
    for part in re.findall(r"[^,\[]+\[[^\]]*\]|[^,]+", stmt[len("import "):]):
        part = re.sub(r"\s+(as|except)\s.*", "", part.strip())
        m = re.match(r"(.*?)/?\[(.*)\]", part)
        if m:
            res += [(m.group(1) + "/" if m.group(1) else "") + x.strip() for x in m.group(2).split(",")]
        else:
            res.append(part)
    return res
def subjects(suite):
    src = open(os.path.join(root, suite)).read()
    found = []
    for s in statements(src):
        for m in modules(s):
            m = m.strip().strip('"')
            for c in [os.path.join(os.path.dirname(suite), m + ".nim")] + [os.path.join(p, m + ".nim") for p in paths]:
                c = os.path.normpath(c)
                if os.path.exists(os.path.join(root, c)):
                    if not c.startswith("src/frontend/viewmodel/tests/"):
                        found.append(c)
                    break
    js_arm = re.search(r"^\s*when\s+(not\s+)?defined\(js\)", src, re.M) is not None
    return found, js_arm

read = lambda f: [l for l in open(os.path.join(work, f)).read().split("\n") if l]
lane, vm_unit, js_only = read("lane.txt"), read("vm-unit.txt"), set(read("js-only.txt"))
patterns = [re.compile(p) for p in read("not-shipped.txt")]
listed = [s for s in vm_unit if any(p.search(s) for p in patterns)]
for p in patterns:
    (ok if any(p.search(s) for s in vm_unit) else bad)(f"the listed suite {p.pattern} exists in vm-unit")
for s in listed:
    subj, js_arm = subjects(s)
    hit = sorted(set(subj) & shipped)
    if hit or js_arm:
        bad(f"{s} is listed as unshipped, but " + (f"{hit[0]} ships under nim js" if hit else "it has a when defined(js) arm") + "; remove it from _TLF_VM_UNIT_JS_NOT_SHIPPED")
    else:
        ok(f"{s}: none of its {len(subj)} subject module(s) ships under nim js")
unshipped_in_lane = 0
for s in lane:
    if s in js_only:
        continue
    subj, js_arm = subjects(s)
    if any("/identity/" in m for m in subj):
        continue
    if not (set(subj) & shipped) and not js_arm:
        unshipped_in_lane += 1
        bad(f"{s} is in vm-unit-js, but none of its subject modules ships under nim js; add it to _TLF_VM_UNIT_JS_NOT_SHIPPED")
if unshipped_in_lane == 0:
    ok(f"every one of vm-unit-js's {len(lane)} suites has a subject that ships under nim js (or is exempt)")
print(f"{checks} checks, {failures} failures; vm-unit {len(vm_unit)}, vm-unit-js {len(lane)}, listed {len(listed)}; "
      + ", ".join(f"{n} {len(m)}" for n, m in bundles.items()))
sys.exit(1 if failures else 0)
PY
rc=$?
[ "${rc}" -eq 0 ] && echo "RESULT: OK" || echo "RESULT: FAILED"
exit "${rc}"
