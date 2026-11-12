#!/usr/bin/env bash
# ci/test/shared-editor-differential.sh — the editor differential: every
# desktop scenario of CodeTracer's scenario pack that drives the editor, run
# with Monaco (`CODETRACER_SHARED_EDITOR=0`) and with the shared editor
# (`=1`), and the two runs' observations compared step by step.
#
# The scenarios are the pack's own (src/tests/scenarios, DemoVideoScript
# format); nothing here is written for the differential. A scenario's run
# record (`manifest.json`, `demo-video-script.run.v1`) carries each step's
# status and what an `expect` step OBSERVED (the editor role's properties:
# the caret, the selection, the stop, the glyph column's marks…). The two
# runs agree when every step has the same status and the same observation;
# where they were drawn on screen (`resolved`, pixels) and how long they
# took are not compared.
#
#   ci/test/shared-editor-differential.sh [scenario.yaml…]
#
# With no arguments: the electron lane's scenarios under editor/,
# breakpoints/, tracing/ and the command palette's symbol choices. Needs
# `ci/test/scenarios.sh build` and `just build-once`, and a display.
# Writes build/shared-editor-differential/{monaco,shared}/<name>.json and
# exits 1 on any difference, naming the scenario, the step and both sides.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${root}"
S=src/tests/scenarios
out="${CT_DIFFERENTIAL_OUT:-${root}/build/shared-editor-differential}"

if [ $# -gt 0 ]; then
	scenarios=("$@")
else
	mapfile -t scenarios < <(grep -oE '\.\./(editor|breakpoints|tracing|command-palette/symbol-)[^ ]*\.yaml' \
		"${S}/lanes/electron.lane.yaml" | sed "s#^\.\./#${S}/#")
fi

rm -rf "${out}"
mkdir -p "${out}/monaco" "${out}/shared"
for sc in "${scenarios[@]}"; do
	name="$(basename "${sc}" .yaml)"
	for side in monaco shared; do
		flag=0
		[ "${side}" = shared ] && flag=1
		run="${out}/runs/${side}/${name}"
		rm -rf "${run}"
		CODETRACER_SHARED_EDITOR="${flag}" bash ci/test/scenarios.sh run electron "${sc}" \
			--record always --out "${run}" >"${out}/${side}/${name}.log" 2>&1
		echo "differential: ${name} ${side} exit $?"
		cp "${run}/manifest.json" "${out}/${side}/${name}.json" 2>/dev/null ||
			echo '{"outcome":"no-manifest","steps":[]}' >"${out}/${side}/${name}.json"
	done
done

python3 - "${out}" <<'EOF'
import json, os, sys
out = sys.argv[1]
names = sorted(f[:-5] for f in os.listdir(os.path.join(out, "monaco")) if f.endswith(".json"))
bad = 0
for name in names:
    m = json.load(open(os.path.join(out, "monaco", name + ".json")))
    s = json.load(open(os.path.join(out, "shared", name + ".json")))
    diffs = []
    if m.get("outcome") != s.get("outcome"):
        diffs.append(f"outcome: monaco {m.get('outcome')!r} shared {s.get('outcome')!r}")
    ms, ss = m.get("steps", []), s.get("steps", [])
    if len(ms) != len(ss):
        diffs.append(f"steps: monaco {len(ms)} shared {len(ss)}")
    for a, b in zip(ms, ss):
        for key in ("status", "observed", "message"):
            if a.get(key) != b.get(key):
                diffs.append(f"step {a.get('index')} {a.get('path')} {key}: "
                             f"monaco {a.get(key)!r} shared {b.get(key)!r}")
    verdict = "SAME" if not diffs else "DIFFERENT"
    print(f"{verdict:9} {name}  (monaco {m.get('outcome')}, shared {s.get('outcome')}, "
          f"{len(ms)} steps)")
    for d in diffs:
        print("    " + d)
    bad += bool(diffs)
print(f"differential: {len(names)} scenario(s), {bad} different")
sys.exit(1 if bad else 0)
EOF
