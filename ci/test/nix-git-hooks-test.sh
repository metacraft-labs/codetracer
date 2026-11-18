#!/usr/bin/env bash
# Drive the exact Nix hook lifecycle used by devShells.default, with the pinned
# git-hooks.nix module and real pre-commit, checker, Git and Repro binaries.
# No hook or publication gate is mocked. The minimal generated checker config
# isolates installation from CodeTracer's unrelated Rust/toolchain checks.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
installer=${CT_TEST_NIX_HOOK_INSTALLER:-$(nix build --impure --no-link --max-jobs 2 --cores 2 --print-out-paths --expr "import $repo/ci/test/nix-git-hooks-fixture.nix {}")}
upgraded_installer=${CT_TEST_NIX_HOOK_UPGRADED_INSTALLER:-$(nix build --impure --no-link --max-jobs 2 --cores 2 --print-out-paths --expr "import $repo/ci/test/nix-git-hooks-fixture.nix { upgraded = true; }")}
unrooted_installer=${CT_TEST_NIX_HOOK_UNROOTED_INSTALLER:-$(nix build --impure --no-link --max-jobs 2 --cores 2 --print-out-paths --expr "import $repo/ci/test/nix-git-hooks-fixture.nix { upgraded = true; addGcRoot = false; }")}
config_file=$(bash "$installer" --config-file)
upgraded_config_file=$(bash "$upgraded_installer" --config-file)
[ "$config_file" != "$upgraded_config_file" ] || {
	echo 'FAIL: upgrade fixture has unchanged configuration bytes' >&2
	exit 1
}
export REPROBUILD_REPRO
REPROBUILD_REPRO=$(bash "$installer" --repro-bin)
scratch=$(mktemp -d)
trap 'rm -rf "${scratch:?}"' EXIT
export GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_CONFIG_NOSYSTEM=1
export PRE_COMMIT_HOME="$scratch/pre-commit-home"
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX PYTHONPATH
printf '[user]\nname = Hook Tester\nemail = hooks@example.invalid\n[commit]\ngpgsign = false\n[init]\ndefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
fail() {
	echo "FAIL: $*" >&2
	exit 1
}
git init -q --bare "$scratch/origin.git"
git init -q "$scratch/main"
mkdir -p "$scratch/main/ci/dev"
cp "$repo"/ci/dev/{should-install-git-hooks,reclaim-hook-dispatchers,git-hooks-path}.sh "$scratch/main/ci/dev/"
printf '.pre-commit-config.yaml\n' >"$scratch/main/.gitignore"
printf 'clean\n' >"$scratch/main/content.txt"
git -C "$scratch/main" add .
git -C "$scratch/main" commit -qm seed
git -C "$scratch/main" remote add origin "$scratch/origin.git"
git -C "$scratch/main" push -qu origin main
(cd "$scratch/main" && bash "$installer")
git -C "$scratch/main" worktree add -q --detach "$scratch/wt" HEAD
[ ! -e "$scratch/wt/.pre-commit-config.yaml" ] || fail 'fixture worktree unexpectedly has generated config'
if ! git -C "$scratch/wt" push --dry-run origin HEAD:refs/heads/main >"$scratch/push.log" 2>&1; then
	cat "$scratch/push.log" >&2
	fail 'a fresh worktree cannot push without entering its dev shell'
fi
echo 'PASS: fresh worktree push uses installed hooks without a generated config'
# A second entry exercises a genuine dispatcher displaced by the two native
# installations, not merely initial bootstrap into an empty hooks directory.
cp "$scratch/main/.git/hooks/pre-push.repro-managed" "$scratch/managed.before"
(cd "$scratch/main" && bash "$installer")
cmp "$scratch/managed.before" "$scratch/main/.git/hooks/pre-push.repro-managed" || fail 'reentry changed the managed gate'
git -C "$scratch/wt" push --dry-run origin HEAD:refs/heads/main >"$scratch/reentry.log" 2>&1 || {
	cat "$scratch/reentry.log" >&2
	fail 'repeat shell entry lost the working hook chain'
}
# Migrate inherited old shims from a LINKED checkout, preserving a dispatcher
# displaced by the real native installer. Another new worktree then needs no
# configuration symlink or shell entry of its own.
(cd "$scratch/main" && bash "$installer" --relative-native)
(cd "$scratch/wt" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=ct.test GIT_CONFIG_VALUE_0=preserved bash "$upgraded_installer" --audit-config) >"$scratch/config-audit.log" 2>&1 || {
	cat "$scratch/config-audit.log" >&2
	fail 'linked migration with inherited command-scope Git config failed'
}
grep -qx preserved "$scratch/config-audit.log" || fail 'migration lost caller command-scope Git configuration'
[ "$(readlink "$scratch/main/.pre-commit-config.yaml")" = "$config_file" ] || fail 'linked migration rewrote the main checkout config link'
# addGcRoot=false must still make the config available, without registering
# that worktree's link as an indirect root.
git -C "$scratch/main" worktree add -q --detach "$scratch/no-gc-wt" HEAD
(cd "$scratch/main" && bash "$installer" --relative-native)
(cd "$scratch/no-gc-wt" && bash "$unrooted_installer")
[ "$(readlink "$scratch/no-gc-wt/.pre-commit-config.yaml")" = "$upgraded_config_file" ] || fail 'addGcRoot=false did not create its plain config symlink'
nix-store --query --roots "$upgraded_config_file" >"$scratch/config-roots.log"
if grep -Fq -- "$scratch/no-gc-wt/.pre-commit-config.yaml ->" "$scratch/config-roots.log"; then
	fail 'addGcRoot=false registered an indirect config root'
fi
grep -Fq -- "$scratch/wt/.pre-commit-config.yaml -> $upgraded_config_file" "$scratch/config-roots.log" || {
	cat "$scratch/config-roots.log" >&2
	fail 'new shared hook configuration is not rooted by the migrated worktree'
}
[ "$(readlink "$scratch/wt/.pre-commit-config.yaml")" = "$upgraded_config_file" ] || fail 'linked migration did not create its new worktree config link'
echo 'PASS: linked migration roots its new configuration while retaining the old main config root'
# Shared hooks outlive the temporary worktree that selected their config.
# Delete that checkout and its manual link, then require a repository-lifetime
# root; a reference from a still-running fixture process is not that guarantee.
git -C "$scratch/main" worktree remove "$scratch/wt"
rm "$scratch/no-gc-wt/.pre-commit-config.yaml"
nix-store --query --roots "$upgraded_config_file" >"$scratch/lifetime-roots.log"
grep -Fq -- "$scratch/main/.git/hooks/.codetracer-pre-commit-config -> $upgraded_config_file" "$scratch/lifetime-roots.log" || {
	cat "$scratch/lifetime-roots.log" >&2
	fail 'shared hook configuration has no repository-lifetime root after its migrating worktree is removed'
}
git -C "$scratch/main" worktree add -q --detach "$scratch/lifetime-fresh" HEAD
[ ! -e "$scratch/lifetime-fresh/.pre-commit-config.yaml" ] || fail 'lifetime control unexpectedly has a worktree config'
git -C "$scratch/lifetime-fresh" push --dry-run origin HEAD:refs/heads/main >"$scratch/lifetime-push.log" 2>&1 || {
	cat "$scratch/lifetime-push.log" >&2
	fail 'new no-config worktree cannot push after the migrating worktree was removed'
}
echo 'PASS: repository-lifetime root retains the shared configuration after migrating worktree removal'
# Recreate the checkout for the remaining managed-gate controls.
git -C "$scratch/main" worktree add -q --detach "$scratch/wt" HEAD
# Isolate root ownership/disabled-root controls so none temporarily remove the
# real root the main fixture's native hooks rely on.
seed_hook_repo() {
	local root=$1
	git init -q "$root"
	mkdir -p "$root/ci/dev"
	cp "$repo"/ci/dev/{should-install-git-hooks,reclaim-hook-dispatchers,git-hooks-path}.sh "$root/ci/dev/"
	printf '.pre-commit-config.yaml\n' >"$root/.gitignore"
	git -C "$root" add .
	git -C "$root" commit -qm seed
}
seed_hook_repo "$scratch/unrooted-main"
(cd "$scratch/unrooted-main" && bash "$unrooted_installer")
if [ -e "$scratch/unrooted-main/.git/hooks/.codetracer-pre-commit-config" ] ||
	[ -L "$scratch/unrooted-main/.git/hooks/.codetracer-pre-commit-config" ]; then
	fail 'addGcRoot=false created a shared config root'
fi
for kind in regular foreign-symlink; do
	root="$scratch/root-$kind"
	seed_hook_repo "$root"
	shared_root="$root/.git/hooks/.codetracer-pre-commit-config"
	if [ "$kind" = regular ]; then
		printf 'foreign root owner\n' >"$shared_root"
	else
		ln -s "$scratch/foreign-config" "$shared_root"
	fi
	if (cd "$root" && bash "$installer") >"$scratch/root-$kind.log" 2>&1; then
		fail "native installation replaced a foreign $kind shared config root"
	fi
	grep -q 'Refusing to replace a foreign shared config root' "$scratch/root-$kind.log" || fail 'installer did not reach its shared-root ownership refusal'
	if [ "$kind" = regular ]; then
		grep -qx 'foreign root owner' "$shared_root" || fail 'installer changed the foreign regular root'
	else
		[ "$(readlink "$shared_root")" = "$scratch/foreign-config" ] || fail 'installer changed the foreign root symlink'
	fi
done

# The config-only path has the same refusal to overwrite regular config as
# the upstream full installer; refusal must preserve both file and dispatcher.
git -C "$scratch/main" worktree add -q --detach "$scratch/config-owner-wt" HEAD
printf 'repos: []\n' >"$scratch/config-owner-wt/.pre-commit-config.yaml"
(cd "$scratch/main" && bash "$installer" --relative-native)
if (cd "$scratch/config-owner-wt" && bash "$upgraded_installer") >"$scratch/migration-refusal.log" 2>&1; then
	fail 'config-only migration replaced an existing regular config'
fi
grep -q 'Refusing to replace an existing config' "$scratch/migration-refusal.log" || fail 'migration did not reach its configuration ownership refusal'
grep -qx 'repos: \[\]' "$scratch/config-owner-wt/.pre-commit-config.yaml" || fail 'migration changed the existing regular config'
grep -q 'reprobuild hook dispatcher' "$scratch/main/.git/hooks/pre-push" || fail 'refused migration lost the managed dispatcher'
(cd "$scratch/wt" && bash "$upgraded_installer")

cmp "$scratch/managed.before" "$scratch/main/.git/hooks/pre-push.repro-managed" || fail 'linked migration changed the managed gate'
git -C "$scratch/main" worktree add -q --detach "$scratch/fresh" HEAD
[ ! -e "$scratch/fresh/.pre-commit-config.yaml" ] || fail 'migration control unexpectedly has a config link'
git -C "$scratch/fresh" push --dry-run origin HEAD:refs/heads/main >"$scratch/migration.log" 2>&1 || {
	cat "$scratch/migration.log" >&2
	fail 'linked-worktree migration left the next fresh worktree broken'
}
cp "$scratch/main/.git/hooks/pre-push.repro-local" "$scratch/native.before"
(cd "$scratch/wt" && bash "$installer")
cmp "$scratch/native.before" "$scratch/main/.git/hooks/pre-push.repro-local" || fail 'healthy linked entry rewrote the native shim'
# Prove that the real configured checker can still refuse a push from the
# worktree. Construct the bad commit before any hooks exist in a separate seed,
# then fetch it; no commit/push bypass is used by the test.
git init -q "$scratch/bad-seed"
printf 'trailing whitespace   \n' >"$scratch/bad-seed/bad.txt"
git -C "$scratch/bad-seed" add bad.txt
git -C "$scratch/bad-seed" commit -qm bad
git -C "$scratch/wt" fetch -q "$scratch/bad-seed" main
git -C "$scratch/wt" checkout -q --detach FETCH_HEAD
if git -C "$scratch/wt" push --dry-run origin HEAD:refs/heads/checker-control >"$scratch/checker.log" 2>&1; then
	fail 'configured whitespace checker accepted a bad push'
fi
grep -q 'trim-trailing-whitespace.*Failed' "$scratch/checker.log" || {
	cat "$scratch/checker.log" >&2
	fail 'checker refusal was not from the configured whitespace checker'
}
git -C "$scratch/wt" restore bad.txt
git -C "$scratch/wt" checkout -q --detach main
# Initialize a real minimal Repro workspace around the published main checkout.
# Publication is local-only: no shared record backend or remote service exists.
mkdir -p "$scratch/.repro" "$scratch/projects" "$scratch/repos" "$scratch/url-prefixes"
cat >"$scratch/.repro/workspace-state.toml" <<'STATE'
schema = "reprobuild.workspace.state.v1"
[workspace]
project = "demo"
STATE
cat >"$scratch/projects/demo.toml" <<'PROJECT'
schema = "reprobuild.workspace.project.v1"
member_repos = ["main"]
[project]
name = "demo"
PROJECT
cat >"$scratch/repos/main.toml" <<'REPO'
schema = "reprobuild.workspace.repo.v2"
[repo]
name = "main"
path = "main"
url_prefix = "local"
mainline = "main"
REPO
cat >"$scratch/url-prefixes/local.toml" <<PREFIX
schema = "reprobuild.workspace.url-prefix.v1"
[url-prefix]
name = "local"
url = "$scratch"
PREFIX
# Bind the genuine hooks to the now-initialized workspace rather than the
# intentionally plain repositories used for the installer checks above.
"$REPROBUILD_REPRO" hooks ensure --vcs "$scratch/main"
if ! git -C "$scratch/main" push --dry-run origin HEAD:refs/heads/gate-control >"$scratch/clean-gate.log" 2>&1; then
	cat "$scratch/clean-gate.log" >&2
	fail 'real initialized workspace rejected its clean published control'
fi
grep -q 'repro check: OK' "$scratch/clean-gate.log" || fail 'clean control did not enforce the real publication gate'
# This tracked edit has no whitespace defect for the configured checker to
# reject, so the managed publication gate must identify the dirty workspace.
printf 'dirty\n' >>"$scratch/main/content.txt"
if git -C "$scratch/main" push --dry-run origin HEAD:refs/heads/gate-control >"$scratch/gate.log" 2>&1; then
	cat "$scratch/gate.log" >&2
	fail 'managed publication gate accepted a dirty workspace'
fi
assert_gate_refusal() {
	local log=$1
	if ! grep -q 'repro check: mode=pre-push' "$log" ||
		! grep -q 'main: dirty.*working tree has uncommitted changes' "$log" ||
		grep -Eq 'not a workspace|no-op|protocol mismatch|could not be evaluated' "$log"; then
		cat "$log" >&2
		fail 'managed refusal did not enforce the real dirty-workspace contract'
	fi
}
assert_gate_refusal "$scratch/gate.log"
git -C "$scratch/main" restore content.txt
printf 'dirty\n' >>"$scratch/wt/content.txt"
if git -C "$scratch/wt" push --dry-run origin HEAD:refs/heads/gate-control >"$scratch/linked-gate.log" 2>&1; then
	fail 'managed publication gate accepted a dirty linked worktree'
fi
assert_gate_refusal "$scratch/linked-gate.log"
git -C "$scratch/wt" restore content.txt
if ! git -C "$scratch/wt" push --dry-run origin HEAD:refs/heads/gate-control >"$scratch/restored-gate.log" 2>&1; then
	cat "$scratch/restored-gate.log" >&2
	fail 'restored clean linked worktree did not pass the real publication gate'
fi
grep -q 'repro check: OK' "$scratch/restored-gate.log" || fail 'restored clean gate did not report enforcement success'
# Upstream deliberately refuses to replace a regular config. The caller has no
# errexit; this must still fail, preserve the managed dispatcher, and never
# print the post-setup success marker.
mv "$scratch/main/.pre-commit-config.yaml" "$scratch/saved-config"
printf 'repos: []\n' >"$scratch/main/.pre-commit-config.yaml"
if (cd "$scratch/main" && bash "$installer") >"$scratch/refusal.log" 2>&1; then
	fail 'installer accepted a config the real git-hooks.nix installer refuses'
fi
grep -q 'Refusing to install because of an existing config' "$scratch/refusal.log" || fail 'control did not reach the real installer refusal'
! grep -q 'CodeTracer hook setup completed' "$scratch/refusal.log" || fail 'failed setup reached its completion marker without errexit'
grep -q 'reprobuild hook dispatcher' "$scratch/main/.git/hooks/pre-push" || fail 'failed installation lost the dispatcher'
rm "$scratch/main/.pre-commit-config.yaml"
mv "$scratch/saved-config" "$scratch/main/.pre-commit-config.yaml"
echo 'PASS: configured checker, dispatcher reentry and real publication gate enforce'
