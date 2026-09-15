#!/usr/bin/env python3
"""Scanner: a step handed a private substituter is also handed a credential for it.

THE DEFECT THIS EXISTS FOR
--------------------------
`setup-nix` writes nix.conf with

    substituters = https://cache.nixos.org $EXTRA_SUBSTITUTERS
    netrc-file   = $HOME/.config/nix/netrc

and this repository's workflows put the org's PRIVATE Attic cache into
`$EXTRA_SUBSTITUTERS`.  For a long time nothing put a credential for that cache
into the netrc, so `GET <cache>/nix-cache-info` answered 401, nix disabled the
substituter and retried forever, and everything not on cache.nixos.org was
built FROM SOURCE.  On the bare-metal runners a warm /nix/store hid it; on the
`eph-*` ephemeral ones, whose store starts empty, it turned every job into a
full toolchain build -- which then failed on unrelated-looking third-party
fetches (crates.io 403s inside cargo-stylus' vendor derivation) in six separate
launcher- and recorder-triggered runs before the cause was found.

Naming a substituter and supplying a credential for it are two edits in two
places, and the failure mode of doing only the first is a job that succeeds
slowly and then dies somewhere else.  That is exactly the kind of omission that
is invisible in review, so it is asserted here instead.

THE PROPERTY, NOT THE SYMPTOM
-----------------------------
For every step in this repository that hands a nix-provisioning action a
NON-EMPTY `substituters:` value:

  * if that action is CREDENTIAL-CAPABLE -- it has a code path that writes the
    cache credential into the netrc nix reads -- the step must also pass a
    non-empty `attic-token`.  In a workflow the value must come from
    `secrets.`, because a credential that came from `vars.` would be a public
    repository variable and a credential written literally would be a committed
    one.  In a composite action it must come from `inputs.`, because
    `secrets.`/`vars.` do not exist in that context at all -- an action that
    spelled it `secrets.ATTIC_TOKEN` would silently pass the empty string.
  * if it is NOT credential-capable, passing a token to it would be inert, so
    the step is not required to -- but the consumer must be named in the
    register beside this file, with a reason.  Silence is the thing that let
    this defect live for months; an enumerated baseline is not silence.

A local composite action counts as credential-capable when it DECLARES an
`attic-token` input and FORWARDS it (as `inputs.attic-token`) into a step that
is itself credential-capable.  Declaring the input and dropping it on the floor
produces exactly the same observable as not having it, so both halves are
required.

Usage:  python3 ci/test/private-substituter-credential.py [REPO_ROOT]
Exit:   0 ok, 1 contract violated, 3 usage/internal error.
Suite:  ci/test/private-substituter-credential-test.sh
"""

import os
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - reported, never silently skipped
    sys.stderr.write("PyYAML is not available; this scanner cannot run.\n")
    sys.exit(3)

# Actions in other repositories that DO write the Attic credential into the
# netrc nix reads.  metacraft-github-actions/setup-nix does it in
# setup-nix/write-nix-netrc.sh; setup-dev-env and setup-reprobuild are thin
# wrappers that forward `attic-token`/`attic-cache` into it.
FOREIGN_CAPABLE = {
    "metacraft-labs/metacraft-github-actions/setup-nix",
    "metacraft-labs/metacraft-github-actions/setup-dev-env",
    "metacraft-labs/metacraft-github-actions/setup-reprobuild",
}

REGISTER = "ci/test/private-substituter-credential.known-dark.txt"

# `substituters: https://cache.nixos.org` alone is not a private cache and needs
# no credential.  Anything else -- an expression, or another URL -- is treated
# as private, which is the safe direction: it demands a credential rather than
# excusing one.
PUBLIC_ONLY = {"https://cache.nixos.org", "https://cache.nixos.org/"}


def norm_ref(uses):
    """owner/repo/path@ref -> owner/repo/path; a local ref is kept as written."""
    return uses.split("@", 1)[0].strip()


def iter_steps(node):
    """Yield every mapping that has a string `uses` key, anywhere in the doc."""
    if isinstance(node, dict):
        if isinstance(node.get("uses"), str):
            yield node
        for value in node.values():
            yield from iter_steps(value)
    elif isinstance(node, list):
        for value in node:
            yield from iter_steps(value)


def load(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def collect_files(root):
    workflows, actions = [], []
    wf_dir = os.path.join(root, ".github", "workflows")
    if os.path.isdir(wf_dir):
        for name in sorted(os.listdir(wf_dir)):
            if name.endswith((".yml", ".yaml")):
                workflows.append(os.path.join(wf_dir, name))
    act_dir = os.path.join(root, ".github", "actions")
    if os.path.isdir(act_dir):
        for name in sorted(os.listdir(act_dir)):
            candidate = os.path.join(act_dir, name, "action.yml")
            if os.path.isfile(candidate):
                actions.append(candidate)
    return workflows, actions


def expr_names(value):
    """The secrets./vars./inputs. references inside an expression value."""
    return set(re.findall(r"\b((?:secrets|vars|inputs)\.[A-Za-z0-9_-]+)", str(value)))


def main(argv):
    here = os.path.dirname(os.path.abspath(__file__))
    root = argv[1] if len(argv) > 1 else os.path.join(here, "..", "..")
    root = os.path.abspath(root)
    workflows, actions = collect_files(root)
    if not workflows:
        sys.stderr.write("no workflows found under " + root + "/.github/workflows\n")
        return 3

    # ---- pass 1: which local composite actions are credential-capable -------
    local_capable = {}
    local_declares = {}
    for path in actions:
        name = "./.github/actions/" + os.path.basename(os.path.dirname(path))
        try:
            doc = load(path)
        except Exception as exc:  # noqa: BLE001 - reported, never skipped
            sys.stderr.write(path + ": cannot parse: " + str(exc) + "\n")
            return 3
        inputs = (doc or {}).get("inputs") or {}
        declares = "attic-token" in inputs
        local_declares[name] = declares
        forwards = False
        for step in iter_steps(doc):
            with_ = step.get("with") or {}
            if not isinstance(with_, dict):
                continue
            token = str(with_.get("attic-token", "")).strip()
            if norm_ref(step["uses"]) in FOREIGN_CAPABLE and "inputs.attic-token" in token:
                forwards = True
        local_capable[name] = declares and forwards

    def capable(ref):
        if ref in FOREIGN_CAPABLE:
            return True
        return local_capable.get(ref, False)

    # ---- pass 2: every step that names a private substituter ---------------
    violations = []
    dark_seen = {}
    scanned = 0
    credentialed = 0

    for path in workflows + actions:
        is_action = os.path.basename(path) == "action.yml"
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        try:
            doc = load(path)
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(path + ": cannot parse: " + str(exc) + "\n")
            return 3
        for step in iter_steps(doc):
            with_ = step.get("with") or {}
            if not isinstance(with_, dict):
                continue
            subs = str(with_.get("substituters", "")).strip()
            if not subs or subs in PUBLIC_ONLY:
                continue
            scanned += 1
            ref = norm_ref(step["uses"])
            if not capable(ref):
                dark_seen.setdefault(ref, []).append(rel)
                continue
            token = str(with_.get("attic-token", "")).strip()
            where = rel + ": step `uses: " + step["uses"] + "` declares substituters `" + subs + "`"
            if not token:
                violations.append(
                    where + " but passes no `attic-token`. nix will read that "
                    "substituter anonymously, get 401 and build from source."
                )
                continue
            names = expr_names(token)
            if is_action:
                if not any(n.startswith("inputs.") for n in names):
                    violations.append(
                        where + " and passes attic-token `" + token + "`, which does "
                        "not come from `inputs.`. A composite action has no `secrets` "
                        "or `vars` context, so that expression is the empty string."
                    )
                    continue
            else:
                if not any(n.startswith("secrets.") for n in names):
                    violations.append(
                        where + " and passes attic-token `" + token + "`, which does "
                        "not come from `secrets.`. A credential taken from `vars.` is "
                        "a public repository variable and a literal one is committed."
                    )
                    continue
            credentialed += 1

    # ---- pass 3: the register of credential-incapable consumers ------------
    register_path = os.path.join(root, REGISTER)
    registered = {}
    if os.path.isfile(register_path):
        with open(register_path, encoding="utf-8") as handle:
            for line in handle:
                line = line.split("#", 1)[0].strip()
                if line:
                    registered[line] = True
    for ref in sorted(dark_seen):
        if ref not in registered:
            violations.append(
                ref + " is handed a private substituter by "
                + str(len(dark_seen[ref])) + " step(s) ("
                + ", ".join(sorted(set(dark_seen[ref])))
                + ") and is not credential-capable, and it is not named in "
                + REGISTER + ". Either make it capable or record it there with a reason."
            )
    for ref in sorted(registered):
        if ref not in dark_seen:
            violations.append(
                ref + " is named in " + REGISTER + " but no step hands it a private "
                "substituter any more. Remove the stale entry -- a register that is "
                "not exact stops being evidence."
            )

    # ---- report ------------------------------------------------------------
    print("steps handing out a private substituter: " + str(scanned))
    print("  credentialed (credential-capable consumer + attic-token): " + str(credentialed))
    print("  credential-incapable consumers (registered): " + str(len(dark_seen)))
    for ref in sorted(dark_seen):
        print("    " + ref + "  <- " + str(len(dark_seen[ref])) + " step(s)")
    for name in sorted(local_capable):
        print(
            "local action " + name
            + ": declares-attic-token=" + str(local_declares[name])
            + " capable=" + str(local_capable[name])
        )

    if violations:
        print()
        for message in violations:
            print("FAIL: " + message)
        return 1
    print("OK: every private substituter is handed out with a credential for it.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
