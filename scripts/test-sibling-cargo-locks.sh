#!/usr/bin/env bash
# =============================================================================
# Sibling Cargo locks — every committed Cargo.lock that resolves crates out of
# the sibling `codetracer-trace-format` checkout must be the lock of the
# trace-format revision this commit PINS, and that pin must be the same in
# `repro.lock` and in `flake.lock`.
#
# ## The defect this exists to catch
#
# `src/db-backend/Cargo.toml` and `src/backend-manager/Cargo.toml` reach five
# trace-format crates by sibling path:
#
#     codetracer_ctfs = { path = "../../../codetracer-trace-format/codetracer_ctfs" }
#
# A path dependency records no source, checksum or revision in Cargo.lock, but
# Cargo DOES write the path crate's own dependency edges into it. The committed
# lock is therefore a function of whatever trace-format tree it was written
# against. When trace-format `afa4dde` added `getrandom = "0.2"` to
# `codetracer_ctfs`, every lock written against the older tree stopped
# resolving against the newer one:
#
#     error: cannot update the lock file …/src/db-backend/Cargo.lock because
#     --locked was passed to prevent this
#
# `src/Tuprules.tup` builds both crates with `cargo build --locked`, so
# `just build-once` died there, before its webpack step; and the cargo-check
# pre-commit hook refused every db-backend commit because the build rewrote the
# lock under it. Meanwhile codetracer's `repro.lock` AND `flake.lock` still
# pinned trace-format at `5da139d7`, so nothing in this repository said the
# locks had fallen behind the sibling — the first sign was a build failure that
# names a flag (`--locked`) rather than the cause (codetracer-pm
# issues/2026-10-20-db-backend-cargo-lock-is-stale-against-the-trace-format-agents-tip.md).
#
# ## The three things that must move together
#
#   repro.lock   codetracer-trace-format revision   — what the workspace syncs
#   flake.lock   codetracer-trace-format locked.rev — what the Nix lane builds
#   Cargo.lock   (each consumer)                    — written against ONE tree
#
# The Nix lane builds db-backend from flake.lock's trace-format with the SAME
# committed Cargo.locks the tup lane uses against the sibling checkout, so a
# lock refreshed against one revision while either pin names another is broken
# in one lane or the other. This script checks, in order:
#
#   1. PINS AGREE — repro.lock and flake.lock name the same trace-format
#      revision. Pure lock comparison; needs no sibling and no cargo.
#   2. LOCKS MATCH THE PIN — every consumer lock is EXACTLY the lock cargo
#      writes for the trace-format tree AT THE PINNED REVISION, materialised
#      from the sibling repository's objects with `git archive` (so neither
#      the sibling's HEAD nor its working tree can influence this verdict).
#      This catches the pins moved without the Cargo.lock refreshed, and a
#      Cargo.lock refreshed without the pins moving.
#   3. LOCKS MATCH THE CHECKOUT — the same comparison against the sibling as
#      it sits on disk, because that is the tree `cargo build --locked` in the
#      tup lane and the cargo-check pre-commit hook actually read. This is the
#      issue's own reproduction: sibling at `afa4dde`, pins and locks at
#      `5da139d7`. When it fails while (2) passes, the commit is
#      self-consistent and the sibling has moved past its pin; the diagnostic
#      says so and names both remedies.
#
# ## Why an exact re-resolution and not `cargo metadata --locked`
#
# `--locked` is what the tup rule uses, and it is NOT strong enough here. It
# refuses a lock that is MISSING an edge, but it accepts a lock that carries an
# edge the tree no longer has. Measured 2026-10-21, nixpkgs cargo 1.92.0: the
# refreshed db-backend and backend-manager locks (with `"getrandom 0.2.17",`
# in `codetracer_ctfs`) pass `cargo metadata --locked --offline` against the
# OLD pinned tree `5da139d7`, and the contract suite's two-crate fixture shows
# the same: `--locked` exits 0 while an unlocked run deletes the stale edge.
# A `--locked` check would therefore pass "Cargo.lock refreshed, pins not
# moved" — while the Nix lane, building flake.lock's older tree, and the
# cargo-check hook, which runs cargo unlocked, would rewrite the lock.
#
# So each check copies the committed lock into a scratch tree, lets cargo
# re-resolve it there with `cargo update --workspace --offline`, and requires
# the result to be byte-identical to the committed lock. Any difference is
# printed as a diff. `--workspace` unlocks only the workspace's own packages and
# keeps every other locked version unless the tree no longer allows it
# (https://doc.rust-lang.org/cargo/commands/cargo-update.html#update-options):
# the same minimal re-resolution an unlocked `cargo build` performs, and NOT
# the broad `cargo update -p <crate>` (see print_remedy). Measured 2026-10-21,
# nixpkgs cargo 1.92.0 at codetracer `4fd359937`: in all three states the
# contract suite models with real locks — the issue's (lock missing the
# getrandom edge, sibling at `afa4dde`), lock refreshed with the pins left at
# `5da139d7`, and fixed — it rewrote exactly the lines an unlocked
# `cargo metadata` rewrote, i.e. the one getrandom edge or nothing.
#
# ## How the tree under test is put where the manifest looks for it
#
# The manifests name the sibling by a RELATIVE path, so the tree under test has
# to sit at `<parent of codetracer>/codetracer-trace-format`. The script builds
# a scratch workspace per check:
#
#     <tmp>/<check>/codetracer               a SHADOW of this checkout: real
#                                            directories along the path to
#                                            each consumer, every other entry a
#                                            symlink into this checkout, and
#                                            the consumer's Cargo.lock a COPY
#     <tmp>/<check>/codetracer-trace-format  `git archive` of the pinned
#                                            revision (check 2), or a symlink
#                                            to the sibling checkout (check 3)
#
# and runs cargo in `<tmp>/<check>/codetracer/<consumer>`. This works because
# Cargo joins a path dependency onto the manifest's directory and normalises
# `..` LEXICALLY rather than through a symlink — measured 2026-10-21 with
# nixpkgs cargo 1.92.0 at codetracer `4062bfe2c`: with the trace-format tree
# missing from the scratch workspace, the error named
# `<tmp>/codetracer-trace-format/codetracer_ctfs`, not the real sibling. The
# Cargo.lock is a copy so that cargo's rewrite lands in the scratch tree and
# never in this checkout. Nothing here is a stub: every byte cargo reads is
# this checkout or a real revision of the real sibling repository.
#
# ## Which manifests are consumers: discovered, not listed
#
# Every git-tracked Cargo.toml is parsed; a manifest is a consumer when one of
# its `path` dependencies (in any dependency, target-dependency, workspace or
# patch table) lands inside `../codetracer-trace-format`, or lands on another
# in-repo manifest that is itself a consumer (a lock written for a crate that
# path-depends on db-backend carries the same edges). Each consumer is checked
# through the nearest git-tracked Cargo.lock at or above it. Finding NO
# consumer is a failure: it means the manifests were restructured and this
# check is asserting about a shape that is gone.
#
# ## Why `cargo update`, and why `--offline`
#
# The verdict is the re-resolved lock, and resolving needs only the registry
# INDEX, never a crate's source. `cargo update` stops there; `cargo metadata`,
# which an earlier version of this script used, goes on to download the source
# of every package it describes, dev-dependencies included. That made the
# check SKIP on a host that had built both crates but never their tests —
# measured 2026-10-21 at codetracer `4fd359937` with a fresh CARGO_HOME after
# `cargo build --locked` of both crates: `cargo metadata --offline` failed to
# download `bitflags v2.9.1` and `anes v0.1.6`, while `cargo update --workspace
# --offline` resolved both locks from the index alone. `just test`'s own
# `test-rust` lane builds backend-manager's `session-manager` but not its
# tests, so CI sits in exactly that state. `--offline` keeps the check
# network-free. A resolution that still fails because the index cache lacks a
# crate (nothing on this host has ever resolved the crate) is NOT reported as a
# stale lock — it is a loud SKIP naming the `cargo fetch` that fills the cache.
#
# ## Skips are loud, never silent; missing tools are failures that name themselves
#
# python3 (to read the TOML/JSON locks) and cargo are required: their absence
# is a hard failure that says which tool is missing and that NOTHING about the
# locks was established. The sibling checkout cannot be synthesised: when it is
# absent, or lacks the pinned revision, checks 2 and 3 print a SKIP naming what
# is missing and the command that fixes it, and the run ends in SKIP, never OK.
# CT_SIBLING_CARGO_LOCKS_STRICT=1 turns every skip into a failure, which is
# what a lane with a guaranteed workspace should do.
#
# The committed Cargo.locks are never modified: cargo only ever writes the
# scratch copies, and the script additionally compares each committed lock
# before and after the run and fails, restoring it, if one changed.
#
# Contract suite: ci/test/sibling-cargo-locks-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
STRICT="${CT_SIBLING_CARGO_LOCKS_STRICT:-0}"
CARGO="${CARGO:-cargo}"

# The repro.lock dep name, the flake.lock root input name, and the directory
# name the Cargo manifests use in their relative paths. All three are spelled
# the same today; they are named separately so a rename of one is a one-line
# change here rather than a silent miss.
SIBLING_NAME="codetracer-trace-format"
SIBLING_DIR="${CT_TRACE_FORMAT_CHECKOUT:-$WORKSPACE_ROOT/$SIBLING_NAME}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

command -v python3 >/dev/null 2>&1 || fail \
	"python3 is required to read repro.lock (TOML), flake.lock (JSON) and the Cargo manifests, and is not on PATH. Run inside the dev shell: 'nix develop --command just test-sibling-cargo-locks'. NOTHING about the trace-format pins or the Cargo.locks has been established by this run."

[ -f "$REPO_ROOT/repro.lock" ] || fail "$REPO_ROOT/repro.lock does not exist; this script must run inside the codetracer checkout."
[ -f "$REPO_ROOT/flake.lock" ] || fail "$REPO_ROOT/flake.lock does not exist; this script must run inside the codetracer checkout."

# print_remedy <target-rev> — the one sanctioned way to move the three
# together. `repro lock update` rewrites BOTH repro.lock and flake.lock (the
# latter through nix, so narHash/lastModified are the real commit's — measured
# 2026-10-21 with repro 0.2.6: a 3-field flake.lock diff and a 1-entry
# repro.lock diff). The Cargo.lock refresh is cargo's MINIMAL re-resolution,
# the one an unlocked `cargo build` performs and the one checks 2 and 3 run;
# `cargo update -p <crate>` asks for more than that and, offline, failed on
# db-backend with a js-sys version conflict against the local index cache.
print_remedy() {
	cat >&2 <<EOF
    repro lock update $SIBLING_NAME --to $1
        (moves repro.lock AND flake.lock; confirm flake.lock with
         scripts/test-flake-lock-node-dates.sh)
    in each consumer lock directory listed above:
        (cd <dir> && cargo update --workspace --offline)
        and review that the Cargo.lock diff touches only the dependency
        edges of the $SIBLING_NAME crates
    bash scripts/test-sibling-cargo-locks.sh
EOF
}

# --- Check 1: PINS AGREE -----------------------------------------------------

# repro_lock_rev <repro.lock> <dep-name> -> revision, or empty when absent.
# The lock is a single-line TOML array under [lock].deps; it is parsed with
# tomllib because a grep would happily match the `depends = "...,<name>,..."`
# string of the self entry instead of the dep's own record.
repro_lock_rev() {
	local out rc
	# shellcheck disable=SC2016
	out="$(python3 -c '
import sys, tomllib
with open(sys.argv[1], "rb") as handle:
    lock = tomllib.load(handle)
for dep in lock.get("lock", {}).get("deps", []):
    if dep.get("name") == sys.argv[2]:
        print(dep.get("revision", ""))
        break
else:
    print("")
' "$1" "$2" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "could not read '$1' as a repro.lock (python3 exited $rc). This is a parse failure, NOT a statement about any pin. Parser output:
$out"
	printf '%s\n' "$out"
}

# flake_lock_rev <flake.lock> <root-input> -> locked.rev, or empty when absent.
# Resolved through `nodes.root.inputs` (and through `follows` paths), never by
# node key: nix suffixes homonymous nodes with `_2`, `_3`, … and hands the
# plain key to whichever was written first (see test-flake-pin-alignment.sh).
flake_lock_rev() {
	local out rc
	# shellcheck disable=SC2016
	out="$(python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    nodes = json.load(handle)["nodes"]

def resolve(start, path):
    current = start
    for segment in path:
        edge = nodes[current]["inputs"][segment]
        current = resolve("root", edge) if isinstance(edge, list) else edge
    return current

name = sys.argv[2]
if name not in nodes.get("root", {}).get("inputs", {}):
    print("")
else:
    node = nodes.get(resolve("root", [name]))
    print(node.get("locked", {}).get("rev", "") if node else "")
' "$1" "$2" 2>&1)"
	rc=$?
	[ "$rc" -eq 0 ] || fail "could not read '$1' as a flake.lock (python3 exited $rc). This is a parse failure, NOT a statement about any pin. Parser output:
$out"
	printf '%s\n' "$out"
}

# `|| exit 1`: the readers run in command substitutions, so their `fail` only
# leaves the subshell.
REPRO_REV="$(repro_lock_rev "$REPO_ROOT/repro.lock" "$SIBLING_NAME")" || exit 1
FLAKE_REV="$(flake_lock_rev "$REPO_ROOT/flake.lock" "$SIBLING_NAME")" || exit 1

[ -n "$REPRO_REV" ] || fail "repro.lock has no '$SIBLING_NAME' dep with a revision. If the dep was renamed or dropped, update this check (scripts/test-sibling-cargo-locks.sh) to match."
[ -n "$FLAKE_REV" ] || fail "flake.lock has no locked rev for root input '$SIBLING_NAME'. If the input was renamed or dropped, update this check (scripts/test-sibling-cargo-locks.sh) to match."

echo "repro.lock  $SIBLING_NAME = $REPRO_REV"
echo "flake.lock  $SIBLING_NAME = $FLAKE_REV"

if [ "$REPRO_REV" != "$FLAKE_REV" ]; then
	cat >&2 <<EOF
FAIL: repro.lock and flake.lock pin DIFFERENT $SIBLING_NAME revisions.

  repro.lock  revision   = $REPRO_REV
  flake.lock  locked.rev = $FLAKE_REV

The workspace (and the tup lane) builds the Rust crates against the first; the
Nix lane builds the same crates, with the same committed Cargo.locks, against
the second. A Cargo.lock can match only one of them. Move both pins to the same
revision and refresh the Cargo.locks against it in the same commit:
EOF
	print_remedy "<sha>"
	exit 1
fi
PINNED_REV="$REPRO_REV"
echo "pins agree: $SIBLING_NAME @ $PINNED_REV"

# --- Discovery ---------------------------------------------------------------

# Prints one line per distinct consumer LOCK: "<lock dir relative to repo>",
# where that directory holds both the Cargo.lock and the Cargo.toml cargo is
# pointed at. Diagnostics (consumer manifests and the paths that made them
# consumers) go to stderr so the caller can show them.
discover_consumers() {
	# shellcheck disable=SC2016
	git -C "$REPO_ROOT" ls-files -z -- '*Cargo.toml' '*Cargo.lock' | python3 -c '
import os, sys, tomllib

repo = os.path.realpath(sys.argv[1])
sibling = os.path.join(os.path.dirname(repo), sys.argv[2])
files = [f for f in sys.stdin.read().split("\0") if f]
manifests = sorted(f for f in files if os.path.basename(f) == "Cargo.toml")
locks = {os.path.dirname(f) for f in files if os.path.basename(f) == "Cargo.lock"}

def dep_tables(doc):
    """Yield every table whose values are dependency specs."""
    kinds = ("dependencies", "dev-dependencies", "build-dependencies")
    for kind in kinds:
        yield doc.get(kind, {})
    for target in doc.get("target", {}).values():
        for kind in kinds:
            yield target.get(kind, {})
    yield doc.get("workspace", {}).get("dependencies", {})
    for patch in doc.get("patch", {}).values():
        yield patch
    yield doc.get("replace", {})

def inside(path, root):
    return path == root or path.startswith(root + os.sep)

# manifest dir (relative) -> (reaches sibling directly?, [in-repo path targets])
edges = {}
reasons = {}
for rel in manifests:
    full = os.path.join(repo, rel)
    if not os.path.isfile(full):
        continue  # tracked but deleted in the working tree
    with open(full, "rb") as handle:
        try:
            doc = tomllib.load(handle)
        except tomllib.TOMLDecodeError as exc:
            sys.exit(f"cannot parse {rel}: {exc}")
    mdir = os.path.dirname(rel)
    direct, internal = [], []
    for table in dep_tables(doc):
        for spec in table.values():
            if not isinstance(spec, dict) or "path" not in spec:
                continue
            # Lexical join, exactly as Cargo resolves it.
            target = os.path.normpath(os.path.join(repo, mdir, spec["path"]))
            if inside(target, sibling):
                direct.append(spec["path"])
            elif inside(target, repo):
                internal.append(os.path.relpath(target, repo))
    edges[mdir] = (direct, internal)
    if direct:
        reasons[mdir] = direct[0]

# Transitive closure over in-repo path edges.
changed = True
while changed:
    changed = False
    for mdir, (_, internal) in edges.items():
        if mdir in reasons:
            continue
        for target in internal:
            if target in reasons:
                reasons[mdir] = f"via {target}"
                changed = True
                break

out = {}
for mdir in sorted(reasons):
    probe = mdir
    while True:
        if probe in locks and os.path.isfile(os.path.join(repo, probe, "Cargo.toml")):
            break
        if probe in ("", "."):
            probe = None
            break
        probe = os.path.dirname(probe)
    if probe is None:
        shown = mdir or "."
        sys.exit(f"{shown}/Cargo.toml reaches {sys.argv[2]} ({reasons[mdir]}) but no git-tracked Cargo.lock sits at or above it; cargo build --locked cannot succeed for it")
    print(f"  consumer: {mdir}/Cargo.toml ({reasons[mdir]}) -> lock {probe}/Cargo.lock", file=sys.stderr)
    out[probe] = True
for probe in out:
    print(probe or ".")
' "$REPO_ROOT" "$SIBLING_NAME"
}

DISCOVERY_LOG_FILE="$(mktemp)"
CONSUMERS_OUT="$(discover_consumers 2>"$DISCOVERY_LOG_FILE")"
rc=$?
DISCOVERY_LOG="$(cat "$DISCOVERY_LOG_FILE")"
rm -f "$DISCOVERY_LOG_FILE"
[ "$rc" -eq 0 ] || fail "consumer discovery failed (exit $rc). This is NOT a statement about any lock:
$DISCOVERY_LOG"
[ -n "$DISCOVERY_LOG" ] && printf '%s\n' "$DISCOVERY_LOG"

CONSUMERS=()
while IFS= read -r line; do
	[ -n "$line" ] && CONSUMERS+=("$line")
done <<<"$CONSUMERS_OUT"

# Refuse vacuity: a universal claim over zero locks is true and worthless.
[ "${#CONSUMERS[@]}" -gt 0 ] || fail "no git-tracked Cargo.toml reaches ../$SIBLING_NAME by path. The manifests were restructured; this check now asserts about a shape that is gone. Update scripts/test-sibling-cargo-locks.sh (or delete it with its recipe) to match."
echo "consumer locks: ${#CONSUMERS[@]}"

# --- Checks 2 and 3 need cargo and the sibling --------------------------------

command -v "$CARGO" >/dev/null 2>&1 || fail \
	"cargo ('$CARGO') is required to resolve the Cargo.locks and is not on PATH. Run inside the dev shell. The pins agree (check 1), but NOTHING about the Cargo.locks has been established by this run — do not read this as a stale lock."

FAILED=0
SKIPPED=0

skip_note() {
	SKIPPED=$((SKIPPED + 1))
	echo "SKIP: $*" >&2
}

failure_note() {
	FAILED=$((FAILED + 1))
	printf 'FAIL: %s\n' "$*" >&2
}

MIRROR="$(mktemp -d)"
LOCK_SNAPSHOT="$(mktemp -d)"
trap 'rm -rf "$MIRROR" "$LOCK_SNAPSHOT"' EXIT HUP INT TERM

# Snapshot every consumer lock so the end-of-run integrity check can both
# detect and undo a modification.
for lockdir in "${CONSUMERS[@]}"; do
	key="$(printf '%s' "$lockdir" | tr '/' '_')"
	cp "$REPO_ROOT/$lockdir/Cargo.lock" "$LOCK_SNAPSHOT/$key.lock"
done

# make_shadow <dest> — the shadow of this checkout described in the header:
# real directories along the path to every consumer lock directory, a COPY of
# each consumer Cargo.lock, and a symlink for every other entry.
make_shadow() {
	# shellcheck disable=SC2016
	python3 -c '
import os, shutil, sys
repo, dest = sys.argv[1], sys.argv[2]
lockdirs = {os.path.normpath(d) for d in sys.argv[3:]}
needed = {"."}
for d in lockdirs:
    while d not in ("", "."):
        needed.add(d)
        d = os.path.dirname(d)
for rel in sorted(needed, key=lambda p: (p.count(os.sep), p)):
    os.makedirs(os.path.join(dest, rel), exist_ok=True)
    for entry in os.listdir(os.path.join(repo, rel)):
        child = os.path.normpath(os.path.join(rel, entry))
        if child in needed:
            continue
        src, dst = os.path.join(repo, child), os.path.join(dest, child)
        if rel in lockdirs and entry == "Cargo.lock":
            shutil.copyfile(src, dst)
        else:
            os.symlink(src, dst)
' "$REPO_ROOT" "$1" "${CONSUMERS[@]}"
}

# resolve_against <label> <tree-path> <tree-description>
#   Lays out <MIRROR>/<label>/{codetracer (shadow), <sibling> -> <tree>},
#   lets cargo re-resolve every consumer lock there, and compares the result
#   with the committed lock. Records stale locks, failures and skips.
resolve_against() {
	local label="$1" tree="$2" what="$3"
	local ws="$MIRROR/$label"
	mkdir -p "$ws"
	if ! make_shadow "$ws/codetracer"; then
		failure_note "could not build the scratch shadow of $REPO_ROOT under $ws. NOTHING about the locks was established against $what."
		return
	fi
	[ -e "$ws/$SIBLING_NAME" ] || ln -s "$tree" "$ws/$SIBLING_NAME"
	local lockdir out rc delta
	for lockdir in "${CONSUMERS[@]}"; do
		# cwd = the shadowed crate dir, so the repo's .cargo/config.toml
		# applies exactly as it does in a real build. No --locked: see
		# "Why an exact re-resolution" in the header.
		out="$(cd "$ws/codetracer/$lockdir" &&
			"$CARGO" update --workspace --offline \
				--manifest-path "$ws/codetracer/$lockdir/Cargo.toml" 2>&1 >/dev/null)"
		rc=$?
		if [ "$rc" -ne 0 ]; then
			case "$out" in
			*"--offline was specified"* | *"attempting to make an HTTP request"* | *"failed to download"* | *"no matching package"*"offline"*)
				skip_note "$lockdir/Cargo.lock against $what could not be re-resolved offline: the local cargo registry cache lacks a crate. This is NOT a verdict on the lock. Fill the cache with: (cd '$REPO_ROOT/$lockdir' && cargo fetch --locked)
$out"
				;;
			*)
				failure_note "cargo update --workspace failed for $lockdir against $what for a reason that is NOT a stale lock (exit $rc). Read cargo's own output:
$out"
				;;
			esac
			continue
		fi
		if cmp -s "$REPO_ROOT/$lockdir/Cargo.lock" "$ws/codetracer/$lockdir/Cargo.lock"; then
			echo "  ok    $lockdir/Cargo.lock is exactly the lock of $what"
			continue
		fi
		STALE+=("$label|$lockdir")
		delta="$(diff -u --label "committed $lockdir/Cargo.lock" --label "re-resolved against $what" \
			"$REPO_ROOT/$lockdir/Cargo.lock" "$ws/codetracer/$lockdir/Cargo.lock" | head -n 60)"
		printf '  STALE %s/Cargo.lock is NOT the lock of %s; cargo re-resolves it as:\n%s\n' \
			"$lockdir" "$what" "$delta" >&2
	done
}

STALE=()

# Check 2 — the PINNED tree, from the sibling's objects only.
PINNED_OK=0
if [ ! -d "$SIBLING_DIR/.git" ] && [ ! -f "$SIBLING_DIR/.git" ]; then
	skip_note "no $SIBLING_NAME checkout at $SIBLING_DIR (set CT_TRACE_FORMAT_CHECKOUT, or clone it beside this repo) — the Cargo.locks were NOT resolved against the pinned revision $PINNED_REV, nor against a checkout."
elif ! git -C "$SIBLING_DIR" cat-file -e "${PINNED_REV}^{commit}" 2>/dev/null; then
	skip_note "the $SIBLING_NAME checkout at $SIBLING_DIR does not have the pinned revision $PINNED_REV, so the Cargo.locks were NOT resolved against it. Run: git -C '$SIBLING_DIR' fetch origin $PINNED_REV"
else
	mkdir -p "$MIRROR/pinned/$SIBLING_NAME"
	if git -C "$SIBLING_DIR" archive --format=tar "$PINNED_REV" | tar -x -C "$MIRROR/pinned/$SIBLING_NAME"; then
		echo "check 2: against the pinned tree $SIBLING_NAME@$PINNED_REV (git archive)"
		resolve_against pinned "$MIRROR/pinned/$SIBLING_NAME" "$SIBLING_NAME@$PINNED_REV (pinned)"
		PINNED_OK=1
	else
		failure_note "could not materialise $SIBLING_NAME@$PINNED_REV with git archive from $SIBLING_DIR."
	fi
fi

# Check 3 — the checkout as it sits on disk (what the tup lane builds).
DISK_DESC=""
if [ -d "$SIBLING_DIR" ] && git -C "$SIBLING_DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; then
	DISK_REV="$(git -C "$SIBLING_DIR" rev-parse HEAD)"
	DISK_DESC="$SIBLING_NAME checkout at $SIBLING_DIR (HEAD $DISK_REV"
	if [ -n "$(git -C "$SIBLING_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
		DISK_DESC="$DISK_DESC + uncommitted changes"
	fi
	DISK_DESC="$DISK_DESC)"
	echo "check 3: against the $DISK_DESC"
	resolve_against disk "$(cd "$SIBLING_DIR" && pwd)" "the $DISK_DESC"
elif [ -d "$SIBLING_DIR/.git" ] || [ -f "$SIBLING_DIR/.git" ]; then
	failure_note "$SIBLING_DIR looks like a git checkout but has no HEAD."
fi

# Integrity: the committed locks must be byte-identical to before the run.
for lockdir in "${CONSUMERS[@]}"; do
	key="$(printf '%s' "$lockdir" | tr '/' '_')"
	if ! cmp -s "$LOCK_SNAPSHOT/$key.lock" "$REPO_ROOT/$lockdir/Cargo.lock"; then
		cp "$LOCK_SNAPSHOT/$key.lock" "$REPO_ROOT/$lockdir/Cargo.lock"
		failure_note "$lockdir/Cargo.lock was MODIFIED during this run (and has been restored). Nothing here may write a committed lock; re-examine this check."
	fi
done

if [ "${#STALE[@]}" -gt 0 ]; then
	FAILED=$((FAILED + ${#STALE[@]}))
	pinned_stale=""
	disk_stale=""
	for entry in "${STALE[@]}"; do
		case "$entry" in
		pinned\|*) pinned_stale="$pinned_stale ${entry#pinned|}/Cargo.lock" ;;
		disk\|*) disk_stale="$disk_stale ${entry#disk|}/Cargo.lock" ;;
		esac
	done
	if [ -n "$pinned_stale" ]; then
		cat >&2 <<EOF

FAIL: committed Cargo.lock(s) do not match the $SIBLING_NAME revision this
      commit pins:
        $pinned_stale

  repro.lock / flake.lock pin  $SIBLING_NAME = $PINNED_REV

A path dependency writes the sibling crate's own dependency edges into the
lock, so a lock is valid for exactly the trace-format tree it was written
against. Either the lock was refreshed against a different trace-format tree
without moving the pins, or the pins moved without refreshing the lock. Move
repro.lock + flake.lock and refresh the Cargo.locks TOGETHER, in one commit:
EOF
		print_remedy "<sha>"
	fi
	if [ -n "$disk_stale" ]; then
		cat >&2 <<EOF

FAIL: committed Cargo.lock(s) do not match the sibling checkout
      that \`cargo build --locked\` (src/Tuprules.tup) actually reads:
        $disk_stale

  pinned (repro.lock, flake.lock)  $SIBLING_NAME = $PINNED_REV
  on disk                          $DISK_DESC

A lock MISSING an edge the checkout has fails the tup build ("cannot update
the lock file ... because --locked was passed"); a lock carrying an edge the
checkout lacks passes --locked but is rewritten by any unlocked cargo run,
which is what fails the cargo-check pre-commit hook. Remedy, one of:

  * adopt the sibling's revision — move both pins and refresh the locks
    together:
EOF
		print_remedy "$DISK_REV"
		cat >&2 <<EOF
  * or put the sibling back on the pin:
        git -C '$SIBLING_DIR' checkout $PINNED_REV
EOF
	fi
fi

if [ "$FAILED" -gt 0 ]; then
	echo "FAIL: $FAILED problem(s); see above." >&2
	exit 1
fi

if [ "$SKIPPED" -gt 0 ] || [ "$PINNED_OK" -ne 1 ]; then
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_SIBLING_CARGO_LOCKS_STRICT=1): $SKIPPED check(s) were skipped; see above." >&2
		exit 1
	fi
	echo "SKIP: the pins agree, but the Cargo.locks were NOT fully verified by this run ($SKIPPED skip(s))." >&2
	exit 0
fi

echo "OK: repro.lock and flake.lock pin $SIBLING_NAME@$PINNED_REV, and all ${#CONSUMERS[@]} consumer Cargo.lock(s) are exactly the locks cargo writes for that tree and for the checkout on disk."
exit 0
