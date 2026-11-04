#!/usr/bin/env bash
#
# web-bundle-default-dir-test.sh — no script assembles a web bundle, by
# default, inside a tup variant directory.
#
# WHY THIS EXISTS
# ---------------
# `ci/test/web-bundle-smoke.sh` and `ci/test/web-bundle-assets.sh` defaulted
# `CT_WEB_BUNDLE_DIR` to `src/build-debug/web`. `src/build-debug/` is tup's
# debug variant directory (it holds a tracked `tup.config`), and tup refuses a
# variant directory holding anything else: "Variant directory must only
# contain a tup.config file. Found extra files: web". The ViewModel job of
# .github/workflows/codetracer.yml runs `just test-web-bundle` before
# `build-once`, so the build could not succeed in a fresh checkout once the
# smoke had run (the 2026-11-02 stabilisation run's viewmodel.log). Both
# defaults now come from `ci/lib/web-bundle-dir.sh`.
#
# WHAT IT HOLDS
# -------------
#   1. the shared default is outside every directory that holds a tracked
#      `tup.config`, and git ignores it (a bundle is never an untracked file);
#   2. every `${CT_WEB_BUNDLE_DIR:-<default>}` with a non-empty default in a
#      script under ci/ or scripts/ takes it from the helper — a literal
#      default would be the third copy, and is checked against rule 1 anyway;
#   3. the two scripts that defaulted to the variant directory are among them
#      (anti-vacuity: a scan that found nothing would hold 2 trivially).
# The predicate behind 1 and 2 is first run on the old default and must flag
# it (the positive control).
#
# Pure bash and git, no toolchain, about a second.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2
# shellcheck source=ci/lib/web-bundle-dir.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/web-bundle-dir.sh"

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
}

# The directories (repo-relative) that hold a tracked tup.config.
mapfile -t variant_dirs < <(git ls-files -- 'tup.config' '*/tup.config' |
	sed -E 's#(^|/)tup\.config$##; s#^$#.#' | sort -u)

# in_variant <repo-relative path> — prints the variant directory it lies in.
in_variant() {
	local p="${1#./}" v
	for v in "${variant_dirs[@]+"${variant_dirs[@]}"}"; do
		if [ "${v}" = "." ] || [ "${p}" = "${v}" ] || [ "${p#"${v}"/}" != "${p}" ]; then
			printf '%s\n' "${v}"
			return 0
		fi
	done
	return 1
}

echo "web-bundle-default-dir-test:"

# 0. The positive control, and that the inventory is not empty.
if [ "${#variant_dirs[@]}" -ge 1 ] && in_variant "src/build-debug/web" >/dev/null; then
	t_pass "the predicate flags the old default src/build-debug/web (variants: ${variant_dirs[*]})"
else
	t_fail "the predicate flags the old default src/build-debug/web (variants: ${variant_dirs[*]-none})"
fi

# 1. The shared default.
default="$(ct_web_bundle_default_dir "${repo_root}")"
rel="${default#"${repo_root}"/}"
if v="$(in_variant "${rel}")"; then
	t_fail "the default ${rel} lies inside the tup variant directory ${v}"
elif ! git check-ignore -q --no-index -- "${rel}/web.js"; then
	t_fail "the default ${rel} is not ignored by git: a bundle would show up as untracked files"
else
	t_pass "the default ${rel} is outside every tup variant directory and ignored by git"
fi

# 2-3. Every default in a script comes from the helper.
literal=""
users=()
# shellcheck disable=SC2016 # the patterns match the scripts' literal text
while IFS=: read -r file _ line; do
	case "${line}" in
	*'${CT_WEB_BUNDLE_DIR:-}'*) continue ;; # no default: the caller's or none
	esac
	if [[ ${line} == *'${CT_WEB_BUNDLE_DIR:-$(ct_web_bundle_default_dir '* ]]; then
		users+=("${file}")
		continue
	fi
	# A literal default: say where it lands, and fail.
	value="$(sed -nE 's/.*\$\{CT_WEB_BUNDLE_DIR:-(.*)\}".*/\1/p' <<<"${line}")"
	literal="${literal}${file}: ${value}$(v="$(in_variant "${value#\$\{repo_root\}/}")" && printf ' (inside tup variant %s)' "${v}")"$'\n'
done < <(grep -rnE '\$\{CT_WEB_BUNDLE_DIR:-' --include='*.sh' ci scripts |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '^ci/test/web-bundle-default-dir-test\.sh:')
if [ -z "${literal}" ]; then
	t_pass "no script under ci/ or scripts/ spells its own CT_WEB_BUNDLE_DIR default"
else
	t_fail "scripts spell their own CT_WEB_BUNDLE_DIR default instead of ct_web_bundle_default_dir:"$'\n'"${literal}"
fi
missing=""
for want in ci/test/web-bundle-smoke.sh ci/test/web-bundle-assets.sh; do
	found=0
	for u in "${users[@]+"${users[@]}"}"; do [ "${u}" = "${want}" ] && found=1; done
	[ "${found}" = 1 ] || missing="${missing} ${want}"
done
if [ -z "${missing}" ]; then
	t_pass "web-bundle-smoke.sh and web-bundle-assets.sh take their default from the helper (${#users[@]} user(s))"
else
	t_fail "these no longer take their default from ct_web_bundle_default_dir:${missing}"
fi

echo "web-bundle-default-dir-test: ${passes} passed, ${failures} failed"
[ "${failures}" -eq 0 ] && [ "${passes}" -eq 4 ]
