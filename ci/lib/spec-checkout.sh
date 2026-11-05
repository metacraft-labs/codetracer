#!/usr/bin/env bash
#
# spec-checkout.sh — where the CodeTracer specification checkout is, for the
# test lanes whose suites read their oracle out of it.
#
# Several Nim suites read a published specification document instead of
# transcribing it (`src/frontend/test_support/spec_documents.nim`): some at
# COMPILE time through `staticRead`, some at run time. That module reads ONE
# place — `$CT_SPECS_DIR` when it is set, else the sibling `../codetracer-pm`
# — and deliberately never searches. A lane that ran with neither got a
# compile error per suite (`cannot open file …/codetracer-pm/spec/…`) that
# reads like a product defect, on every tree, which is how the four
# spec-reading oracle suites stayed red unnoticed: in a workspace the
# specification repository is checked out under its manifest path,
# `codetracer-specs`, not under its GitHub name.
#
# So the LANE RUNNER resolves the checkout once, before it compiles anything,
# and exports the answer as `CT_SPECS_DIR` (an absolute path) for every suite
# it runs. `spec_documents.nim` keeps its no-fallback rule: by the time a
# suite is compiled the variable names exactly one checkout.
#
# The order, first match wins:
#
#   1. `$CT_SPECS_DIR`, when set. An override is never second-guessed: when
#      it does not hold a `spec/` tree the lane fails, naming it, rather than
#      falling through to another checkout the caller did not ask for.
#   2. A sibling named `codetracer-pm` (the published name; what CI clones).
#   3. The checkout the WORKSPACE MANIFEST declares: `repos/<name>.toml` of
#      the reprobuild workspace this checkout sits in, for the repository
#      published as `codetracer-pm` (formerly `codetracer-specs`) — its
#      `path = "…"`, relative to the workspace root.
#      When that checkout is on a branch from before the pm layout (no
#      `spec/`; the workspace's shared checkout is often on someone's working
#      branch), the branch the manifest declares (`branch = "latest"`) is read
#      instead, from the checkout's own `origin/<branch>`: a snapshot of that
#      commit is extracted once into `${TMPDIR:-/tmp}/ct-specs-<commit>` and
#      used. The shared checkout itself is never moved or written.
#   4. A sibling named `codetracer-specs` (the retired name).
#
# Steps 2 – 4 are tried beside THIS checkout and, for a git worktree that
# lives elsewhere, beside the main checkout it belongs to.
#
# A candidate counts only when it holds `spec/` (the pm layout every reader
# expects since codetracer-specs `1735345d`). When nothing counts, the caller
# gets the list of places that were tried, so the failure names its remedy.
#
# Usage (sourced):
#   ct_resolve_specs_dir <repo-root>
#     prints the absolute checkout and returns 0, or prints the places tried
#     (one per line) on stderr and returns 1.

_ct_specs_names="codetracer-pm codetracer-specs"
# The repository's names in a manifest fragment, published name first.

_ct_specs_usable() {
	[ -n "${1:-}" ] && [ -d "$1/spec" ]
}

_ct_specs_manifest_field() {
	# Field `$2` (`path`, `branch`) of the manifest fragment for the
	# specification repo in workspace `$1`, or nothing.
	local _ws="$1" _field="$2" _name _toml
	for _name in ${_ct_specs_names}; do
		_toml="${_ws}/repos/${_name}.toml"
		[ -f "${_toml}" ] || continue
		sed -n "s/^[[:space:]]*${_field}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
			"${_toml}" | head -n 1
		return 0
	done
}

_ct_specs_snapshot() {
	# A snapshot of `origin/<branch>` of the checkout `$1`, when that commit
	# has the pm layout: extracted once, keyed by the commit.
	local _repo="$1" _branch="$2" _commit _dir
	[ -n "${_branch}" ] || return 1
	_commit="$(git -C "${_repo}" rev-parse --verify -q "origin/${_branch}^{commit}" 2>/dev/null)" || return 1
	git -C "${_repo}" cat-file -e "${_commit}:spec" 2>/dev/null || return 1
	_dir="${TMPDIR:-/tmp}/ct-specs-${_commit}"
	if ! _ct_specs_usable "${_dir}"; then
		rm -rf "${_dir}.partial" && mkdir -p "${_dir}.partial" &&
			git -C "${_repo}" archive "${_commit}" | tar -x -C "${_dir}.partial" &&
			rm -rf "${_dir}" && mv "${_dir}.partial" "${_dir}" || return 1
	fi
	echo "${_dir}"
}

ct_resolve_specs_dir() {
	local _root="$1" _tried="" _parent _ws _rel _cand _name _common _branch _snap
	if [ -n "${CT_SPECS_DIR:-}" ]; then
		if _ct_specs_usable "${CT_SPECS_DIR}"; then
			(cd "${CT_SPECS_DIR}" && pwd)
			return 0
		fi
		echo "CT_SPECS_DIR=${CT_SPECS_DIR} (set by the caller; it has no spec/ directory)" >&2
		return 1
	fi
	local _parents
	_parents="$(cd "${_root}/.." && pwd)"
	_common="$(git -C "${_root}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
	if [ -n "${_common}" ] && [ "$(basename "${_common}")" = ".git" ]; then
		_parent="$(cd "$(dirname "${_common}")/.." 2>/dev/null && pwd || true)"
		if [ -n "${_parent}" ] && [ "${_parent}" != "${_parents}" ]; then
			_parents="${_parents}
${_parent}"
		fi
	fi
	while read -r _ws; do
		[ -n "${_ws}" ] || continue
		# The canonical name first: a checkout under the published name is
		# never overridden by an older one under the retired name.
		_cand="${_ws}/codetracer-pm"
		if _ct_specs_usable "${_cand}"; then
			(cd "${_cand}" && pwd)
			return 0
		fi
		_tried="${_tried}${_cand}
"
		_rel="$(_ct_specs_manifest_field "${_ws}" path)"
		if [ -n "${_rel}" ]; then
			_cand="${_ws}/${_rel}"
			if _ct_specs_usable "${_cand}"; then
				(cd "${_cand}" && pwd)
				return 0
			fi
			_branch="$(_ct_specs_manifest_field "${_ws}" branch)"
			if _snap="$(_ct_specs_snapshot "${_cand}" "${_branch}")"; then
				echo "spec-checkout: ${_cand} has no spec/ (on another branch);" \
					"reading the manifest's origin/${_branch} from ${_snap}" >&2
				echo "${_snap}"
				return 0
			fi
			_tried="${_tried}${_cand} (declared by ${_ws}/repos/; no spec/ directory, and no origin/${_branch:-<branch>} with one)
"
		fi
		_cand="${_ws}/codetracer-specs"
		if _ct_specs_usable "${_cand}"; then
			(cd "${_cand}" && pwd)
			return 0
		fi
		_tried="${_tried}${_cand}
"
	done <<<"${_parents}"
	printf '%s' "${_tried}" >&2
	return 1
}
