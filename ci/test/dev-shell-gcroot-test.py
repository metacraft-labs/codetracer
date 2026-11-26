#!/usr/bin/env python3
"""dev-shell-gcroot-test.py -- a long build runs from a dev shell some GC root keeps alive.

`nix develop --command` replaces itself with the command, so while a build runs
nothing roots the store paths it runs from. On a host whose daemon collects
below `min-free`, that collection deleted part of Nim's lib/ under a compiling
ct_cli (macOS runner m3-mcl-001, run 43935388749: `cannot open file:
std/private/osseps`). So:

1. provision-repro-lock-siblings roots this repository's `ci` shell, and its
   default shell unless the caller says `root-default-shell: "false"`, under
   `$RUNNER_TEMP/ct-gcroots`, and exports that directory as CT_GCROOT_DIR;
2. every step of the CI workflows that enters a SIBLING checkout's dev shell
   (it `cd`s to `../<repo>`, or runs in a `working-directory` there) passes
   `--profile` to each of its `nix develop`s;
3. the two scripts that enter a sibling shell themselves (the justfile's
   ensure-ct-native-replay, ci/test/gpui-window-captures.sh) add `--profile`
   under CT_GCROOT_DIR when it is set.

Negative control: with every `--profile ...` stripped from the live workflows,
the checker must name every step it lost.
"""

import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
# codetracer.yml and every workflow it calls (`uses: ./.github/workflows/X`),
# read from the file so a job split out of it later is still checked.
WORKFLOWS = ["codetracer.yml"] + list(dict.fromkeys(re.findall(
    r"^    uses: \./\.github/workflows/(\S+)$",
    (ROOT / ".github/workflows/codetracer.yml").read_text(), re.M)))
ACTION = ROOT / ".github/actions/provision-repro-lock-siblings/action.yml"

failures = 0


def ok(msg):
    print(f"  ok   {msg}")


def bad(msg, *detail):
    global failures
    failures += 1
    print(f"  FAIL {msg}")
    for d in detail:
        print(f"         {d}")


DEVELOP = re.compile(r"\bnix develop\b[^\n]*")


def sibling_occurrences(run, wd):
    """Each `nix develop` in a step's script that runs in a sibling checkout:
    the last `cd` before it went to `../<repo>` and no `)` closed that
    subshell since, or the step's working-directory is a sibling. Comment
    lines do not count."""
    script = "\n".join(l for l in run.splitlines() if not l.lstrip().startswith("#"))
    wd_sibling = "/../" in wd or wd.startswith("..")
    for m in DEVELOP.finditer(script):
        before = script[:m.start()]
        cds = list(re.finditer(r"\bcd\s+([^;&|\n)]+)", before))
        if cds:
            last = cds[-1]
            target = last.group(1)
            closed = ")" in before[last.end():]
            in_sibling = ".." in target and not closed
        else:
            in_sibling = wd_sibling
        # `nix develop "${{ github.workspace }}"` names this repository's own
        # (provision-rooted) shell from wherever the step stands.
        if in_sibling and "github.workspace }}\"" not in m.group(0).split("--command")[0]:
            yield m.group(0)


def violations(text, name):
    found = []
    doc = yaml.safe_load(text)
    for job_id, job in (doc.get("jobs") or {}).items():
        for step in (job or {}).get("steps") or []:
            run = step.get("run")
            if not isinstance(run, str):
                continue
            wd = str(step.get("working-directory", ""))
            for occ in sibling_occurrences(run, wd):
                if "--profile" not in occ:
                    found.append(f"{name}: {job_id}: {step.get('name', '?')}: {occ[:90]}")
    return found


def main():
    print("== a long build runs from a dev shell a GC root keeps alive")
    action = ACTION.read_text()
    if re.search(r'nix develop \.#ci --profile "\$roots/', action) and \
            re.search(r'nix develop --profile "\$roots/codetracer-default"', action) and \
            'CT_GCROOT_DIR=$roots' in action:
        ok("provision-repro-lock-siblings roots the ci and default shells and exports CT_GCROOT_DIR")
    else:
        bad("provision-repro-lock-siblings does not root the ci and default shells under CT_GCROOT_DIR")

    total = 0
    for wf in WORKFLOWS:
        text = (ROOT / ".github/workflows" / wf).read_text()
        v = violations(text, wf)
        if v:
            bad(f"{wf}: a sibling dev shell is entered without a GC root", *v)
        else:
            ok(f"{wf}: every sibling dev shell its steps enter is GC-rooted")
        stripped = re.sub(r'--profile\s+"[^"]*"\s*', "", text)
        total_live = len(violations(stripped, wf))
        total += total_live
    if total > 0:
        ok(f"with --profile stripped, the checker names {total} unrooted sibling dev shell(s)")
    else:
        bad("with --profile stripped the checker names nothing: it cannot fail")

    just = (ROOT / "justfile").read_text()
    gwc = (ROOT / "ci/test/gpui-window-captures.sh").read_text()
    if 'gcroot=(--profile "${CT_GCROOT_DIR}/codetracer-native-backend-shell")' in just and \
            'gcroot=(--profile "${CT_GCROOT_DIR}/isonim-gpui-shell")' in gwc:
        ok("ensure-ct-native-replay and gpui-window-captures.sh root their sibling shells under CT_GCROOT_DIR")
    else:
        bad("ensure-ct-native-replay or gpui-window-captures.sh enters a sibling shell without a GC root")

    if failures:
        print(f"dev-shell-gcroot: {failures} failure(s)")
        return 1
    print("dev-shell-gcroot: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
