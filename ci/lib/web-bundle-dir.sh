#!/usr/bin/env bash
# shellcheck shell=bash
#
# web-bundle-dir.sh — where a web bundle is assembled when the caller does not
# say (`CT_WEB_BUNDLE_DIR` unset): `<checkout>/build/web`.
#
# Sourceable:
#   source "${repo_root}/ci/lib/web-bundle-dir.sh"
#   out_dir="${CT_WEB_BUNDLE_DIR:-$(ct_web_bundle_default_dir "${repo_root}")}"
#
# WHY IT IS NOT `src/build-debug/web` ANY MORE
# --------------------------------------------
# `ci/test/web-bundle-smoke.sh` (`just test-web-bundle`) and
# `ci/test/web-bundle-assets.sh` (`just test-web-bundle-assets`) each defaulted
# to `src/build-debug/web`, inside a build output tree. The tup build that owned
# that tree refused a directory holding anything it had not created ("Variant
# directory must only contain a ... file. Found extra files: web"). The
# `ViewModel` job of .github/workflows/codetracer.yml runs
# `just test-web-bundle` BEFORE its `build-once` step, on `agents` and on
# `dev`, so in a fresh checkout the second step could never succeed once the
# first had run: measured in the 2026-11-02 stabilisation run's viewmodel.log.
# A build output tree belongs to the build whatever the build is, so the
# default stays out of it.
#
# One definition, here, for both scripts, so they cannot drift apart again;
# `ci/test/web-bundle-default-dir-test.sh` fails when the default (or a
# literal default in any script) lies inside a build output directory
# (`src/build-*`), or is not ignored by git.
#
# `build/` is the checkout's untracked build-output root (`/build/` in
# .gitignore; reprobuild's recipe writes `build/generated/` and `build/c/`
# there) and lies outside `src/`, where the build trees are, entirely.

ct_web_bundle_default_dir() {
	local root="${1:?ct_web_bundle_default_dir: the checkout root is required}"
	printf '%s\n' "${root%/}/build/web"
}
