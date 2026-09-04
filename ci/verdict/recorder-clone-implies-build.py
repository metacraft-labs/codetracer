#!/usr/bin/env python3
"""Assert that a job cloning a COMPILED recorder sibling also builds it.

exit 0 -> every clone of a compiled recorder is followed by a build in the
          same job
exit 1 -> at least one is not; each violation names the job and the recorder
exit 2 -> the check examined nothing, or the workflow could not be read

Usage: ci/verdict/recorder-clone-implies-build.py [WORKFLOW ...]
       defaults to .github/workflows/codetracer.yml

WHY THIS CHECK EXISTS
---------------------
Cloning a recorder sibling is not the same claim as being able to use it. The
ruby and JS recorders are COMPILED -- a Rust cdylib and a bundled CLI -- and
neither artefact is committed. A job that clones and does not build gets a tree
that looks complete and fails later, inside a loader or a Playwright fixture,
naming a file the reader has never seen.

Both halves of that were live in codetracer.yml at once:

  * ruby -- `grep -E 'rake compile|extconf|build-extension'` over `.github/`
    returned ZERO hits. The extension was built only by
    scripts/build-siblings.sh, reached solely by the LINUX ct-test-providers
    job, while `test-non-gui` and `test-ui-tests` cloned it on macOS and ran
    against a tree with no compiled artefact.

  * js -- the clone was added to `test-ui-tests` to fix "the job never cloned
    codetracer-js-recorder", but no build came with it. `npm run build`
    appeared in the repository only inside the COMMENT on that clone step.
    scripts/materialize-recording.sh needs packages/cli/dist/index.js, which is
    produced and never committed.

Neither was loud, because scripts/detect-siblings.sh probed a checked-in
wrapper rather than a built artefact and so reported both as present. The
detector is fixed separately (ci/test/detect-siblings-recorder-artifacts-test.sh);
this check covers the other half, since an honest detector reporting "not
built" is still a red job when nothing builds it.

WHAT IS NOT ASSERTED, AND WHY
-----------------------------
The PYTHON recorder is deliberately absent from the table below. It is a
maturin/pyo3 extension and equally compiled, but nix/shells/main.nix's shell
hook builds `.python-recorder-venv` and installs the recorder into it on every
`nix develop`, and when it cannot it leaves CODETRACER_PYTHON_INTERPRETER unset
and writes `.python-recorder-venv/.broken`, which
scripts/test-python-version-alignment.sh fails on. So python has a build path
and a gate already; requiring a workflow step for it would be a false failure.
That was checked rather than assumed.

Contract suite: ci/test/recorder-clone-implies-build-test.sh
"""

import sys
import pathlib

try:
    import yaml
except ImportError:  # pragma: no cover
    print("recorder-clone-implies-build: PyYAML is required", file=sys.stderr)
    sys.exit(2)


# repo -> (human name, substrings that identify a build of it in a `run:` block)
#
# The markers are the BUILD COMMANDS, not the artefact paths: a step that only
# asserts an artefact it never produced would otherwise satisfy this check.
COMPILED_RECORDERS = {
    "codetracer-ruby-recorder": (
        "ruby recorder native extension",
        ("build-extension", "rake compile", "extconf", "build-siblings.sh"),
    ),
    "codetracer-js-recorder": (
        "js recorder CLI",
        ("just build", "npm run build", "build-siblings.sh"),
    ),
}


def parse_justfile(path):
    """Return {recipe_name: (deps, body)} for a Justfile.

    A step may delegate the build to a `just` target rather than spelling it
    out -- `viewmodel-tests` does exactly that, and its recipe
    `test-vm-recorder-gated` runs
    `scripts/build-siblings.sh --only codetracer-js-recorder`. A checker that
    read only the workflow would call that job a violation, which would be a
    FALSE POSITIVE: the build is real, it is just one level down. Reporting it
    would train the reader to ignore this check, so the check follows the call
    instead of being relaxed to permit it.
    """
    recipes = {}
    if not path.exists():
        return recipes
    name = None
    deps = []
    body = []
    for line in path.read_text().splitlines():
        if line[:1] not in (" ", "\t", "") and ":" in line and not line.startswith("#"):
            head, _, rest = line.partition(":")
            if "=" in head or head.strip().startswith("["):
                continue
            if name is not None:
                recipes[name] = (deps, "\n".join(body))
            name = head.split()[0].strip() if head.split() else None
            deps = [d for d in rest.split() if not d.startswith("#")]
            body = []
        elif name is not None and (line.startswith(" ") or line.startswith("\t")):
            body.append(line)
    if name is not None:
        recipes[name] = (deps, "\n".join(body))
    return recipes


def expand_just_targets(text, recipes, _seen=None):
    """Append the bodies of any `just <target>` invoked in `text`."""
    if _seen is None:
        _seen = set()
    out = [text]
    words = text.split()
    for i, w in enumerate(words):
        if w == "just" or w.endswith("/just"):
            for cand in words[i + 1:i + 3]:
                if cand in recipes and cand not in _seen:
                    _seen.add(cand)
                    deps, body = recipes[cand]
                    out.append(body)
                    out.append(expand_just_targets(body, recipes, _seen))
                    for d in deps:
                        if d in recipes and d not in _seen:
                            _seen.add(d)
                            out.append(recipes[d][1])
                    break
    return "\n".join(out)


def step_clones(step):
    """Return the recorder repo a step clones, or None."""
    if not isinstance(step, dict):
        return None
    with_ = step.get("with") or {}
    repo = with_.get("repo")
    if not isinstance(repo, str):
        return None
    name = repo.split("/")[-1]
    return name if name in COMPILED_RECORDERS else None


def step_builds(step, repo, recipes):
    """True if this step's `run:` block -- or a `just` target it invokes -- builds `repo`."""
    if not isinstance(step, dict):
        return False
    run = step.get("run")
    if not isinstance(run, str):
        return False
    run = expand_just_targets(run, recipes)
    # The step must reference the repo AND a build command. Requiring both
    # keeps `cd ../codetracer-ruby-recorder && ls` from counting, and keeps a
    # `just build` for some unrelated sibling from counting either.
    if repo not in run:
        return False
    _, markers = COMPILED_RECORDERS[repo]
    return any(m in run for m in markers)


def main(argv):
    paths = argv[1:] or [".github/workflows/codetracer.yml"]
    violations = []
    clones_seen = 0
    # ci/verdict/<this file> -> ci/verdict -> ci -> repo root: three levels.
    repo_root = pathlib.Path(__file__).resolve().parent.parent.parent
    recipes = parse_justfile(repo_root / "Justfile")

    for path in paths:
        p = pathlib.Path(path)
        if not p.exists():
            print(f"recorder-clone-implies-build: no such workflow: {path}", file=sys.stderr)
            return 2
        doc = yaml.safe_load(p.read_text())
        for job_id, job in (doc.get("jobs") or {}).items():
            steps = job.get("steps") or []
            cloned = {}
            for idx, step in enumerate(steps):
                repo = step_clones(step)
                if repo:
                    cloned.setdefault(repo, idx)
                    clones_seen += 1
            for repo, clone_idx in cloned.items():
                label, _ = COMPILED_RECORDERS[repo]
                # The build must come AFTER the clone; a build step above the
                # clone would run against whatever the previous job left.
                if not any(step_builds(s, repo, recipes) for s in steps[clone_idx + 1:]):
                    violations.append(
                        f"{path}: job '{job_id}' clones {repo} but never builds it "
                        f"({label}). The clone leaves a tree with no compiled "
                        f"artefact; the failure surfaces later, in a loader."
                    )

    if clones_seen == 0:
        # A pass over an empty set is the failure this campaign hit twice.
        print(
            "recorder-clone-implies-build: ERROR examined 0 recorder clones. "
            "Either the workflow moved or clone steps stopped being recognised. "
            "Refusing to report a pass on an empty set.",
            file=sys.stderr,
        )
        return 2

    if violations:
        for v in violations:
            print(f"recorder-clone-implies-build: VIOLATION {v}", file=sys.stderr)
        print(
            f"recorder-clone-implies-build: {len(violations)} violation(s) "
            f"across {clones_seen} recorder clone(s).",
            file=sys.stderr,
        )
        return 1

    print(
        f"recorder-clone-implies-build: ok: all {clones_seen} recorder clone(s) "
        f"are followed by a build in the same job.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
