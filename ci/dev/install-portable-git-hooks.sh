#!/usr/bin/env bash
#
# install-portable-git-hooks.sh -- install the non-Nix leg of this repository's
# commit and push checks.
#
#   bash ci/dev/install-portable-git-hooks.sh [--hooks-dir DIR] [--force]
#
# The Nix dev shell installs the checks nix/pre-commit.nix declares through
# git-hooks.nix, as a `pre-commit` shim whose shebang is a /nix/store bash. This
# installs the same checks for a host without Nix -- native Windows is the case
# that motivated it -- as a shim that runs ci/dev/portable-pre-commit.sh. The
# two are alternatives for the same slot; see "SHARED CHECKOUTS" below.
#
# WHERE THE SHIM GOES. Reprobuild owns `.git/hooks/<hook>` in this workspace and
# runs a repository's own hook from `<hook>.repro-local` (reprobuild-specs
# CLI/hooks.md, "Coexistence Model"). When the dispatcher is there, the shim is
# written as `<hook>.repro-local`; when it is not, as `<hook>` itself, and a
# later `repro hooks ensure --vcs` moves it aside into `.repro-local` exactly as
# it does the Nix shim.
#
# WHAT IT REPLACES AND WHAT IT REFUSES TO. An existing slot holding this
# installer's own shim is rewritten (idempotent). One holding the `pre-commit`
# framework's generated shim -- the Nix path's -- is replaced, and says so. Any
# other file is somebody's hook, and is left alone unless --force.
#
# SHARED CHECKOUTS. A checkout used from both Windows and a Nix shell (a WSL
# distribution on the same disk) has ONE hooks directory. Each side installs its
# own shim on entry -- the Nix shell through its shellHook, Windows through
# env.ps1 or this script -- and the last one wins. Neither can run the other's:
# the Nix shim's interpreter is a /nix/store path, and this shim needs a Python
# the Nix shell may lack. Re-run the installer for the side you are on.
#
# Contract suite: ci/test/portable-pre-commit-test.sh
set -euo pipefail

say() { echo "install-portable-git-hooks: $*" >&2; }

hooks_dir=
force=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--hooks-dir)
		hooks_dir=$2
		shift 2
		;;
	--force)
		force=1
		shift
		;;
	*)
		say "unknown argument: $1"
		exit 2
		;;
	esac
done

repo_root=$(git rev-parse --show-toplevel)

# LINKED WORKTREES RUN NO HOOKS under the core.hooksPath git-hooks.nix writes
# from the main checkout: the RELATIVE `.git/hooks`. git resolves a relative
# hooks path against the toplevel of whichever worktree runs the hook, and in a
# linked worktree `.git` is a file, so the path names nothing and git runs no
# hook at all -- no error, no warning; commits and pushes simply go unchecked.
#
# The value is removed, not made absolute. Unset, git uses
# `$GIT_COMMON_DIR/hooks` from every worktree -- the same directory the relative
# value meant from the main checkout. An absolute value would be spelled for
# one OS only, and in a checkout shared with a Nix shell (WSL on the same disk)
# `M:/...` is a RELATIVE path to Linux git and `/mnt/m/...` a nonexistent one
# to Windows git: the same silent no-hooks failure, moved to the other side.
# Only a global or system core.hooksPath would then win over the default, and
# only in that case is an absolute local value written, to keep outranking it.
#
# Touched only when the relative value resolves, from the main checkout, to
# the common hooks directory; anything else is somebody's deliberate choice.
# A Nix dev shell entered from the main checkout writes `.git/hooks` again when
# it reinstalls; the next run of this installer (env.ps1 runs it) removes it.
anchor_hooks_path() {
	local current common main_wt resolved wanted
	current=$(git config --local --get core.hooksPath) || return 0
	case "$current" in
	/* | [A-Za-z]:[\\/]* | '~'*) return 0 ;;
	esac
	common=$(git rev-parse --path-format=absolute --git-common-dir)
	main_wt=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
	wanted=$(CDPATH='' cd -- "$common/hooks" 2>/dev/null && pwd -P) || return 0
	resolved=$(CDPATH='' cd -- "$main_wt" && CDPATH='' cd -- "$current" 2>/dev/null && pwd -P) || resolved=
	if [ "$resolved" != "$wanted" ]; then
		say "core.hooksPath is the relative '$current', which is not this repository's"
		say "  common hooks directory; leaving it as it is."
		return 0
	fi
	if git config --global --get core.hooksPath >/dev/null 2>&1 ||
		git config --system --get core.hooksPath >/dev/null 2>&1; then
		wanted=$(CDPATH='' cd -- "$wanted" && { pwd -W 2>/dev/null || pwd; })
		git config --local core.hooksPath "$wanted"
		say "core.hooksPath: the relative '$current' ran no hooks in linked worktrees;"
		say "  a global/system core.hooksPath exists, so it is now the absolute $wanted"
	else
		git config --local --unset-all core.hooksPath
		say "core.hooksPath: removed the relative '$current', which ran no hooks in"
		say "  linked worktrees. Unset, every worktree uses $common/hooks."
	fi
}

if [ -z "$hooks_dir" ]; then
	anchor_hooks_path
	# `--path-format=absolute` itself dies ("Not a directory") in the case the
	# block below exists to explain, so fall back to the relative answer.
	hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) ||
		hooks_dir="$repo_root/$(git rev-parse --git-path hooks)"
	if [ ! -d "$hooks_dir" ]; then
		# The case that is easy to miss: git-hooks.nix writes core.hooksPath as
		# the RELATIVE `.git/hooks`, which git resolves against each worktree's
		# toplevel. In a linked worktree `.git` is a file, the path names nothing,
		# and git runs no hooks there at all -- silently.
		say "the hooks directory git would use here does not exist:"
		say "  $hooks_dir   (core.hooksPath=$(git config --get core.hooksPath || echo '<unset>'))"
		say "no hook of any kind runs in this checkout. Point --hooks-dir at the"
		say "directory the main checkout uses, or set core.hooksPath to an absolute path."
		exit 1
	fi
fi

marker="managed-by: ci/dev/install-portable-git-hooks.sh"

for hook in pre-commit pre-push; do
	target="$hooks_dir/$hook"
	if [ -f "$target" ] && grep -q 'reprobuild hook dispatcher' "$target" 2>/dev/null; then
		target="$hooks_dir/$hook.repro-local"
	fi
	if [ -f "$target" ] && ! grep -q "$marker" "$target" 2>/dev/null; then
		if grep -q 'File generated by pre-commit' "$target" 2>/dev/null; then
			say "replacing the pre-commit framework shim at $target"
			say "  (its interpreter: $(head -n 1 "$target" | sed 's/^#!//'))"
			say "  entering the Nix dev shell reinstalls that one; see SHARED CHECKOUTS in $0"
		elif [ "$force" -eq 1 ]; then
			say "--force: replacing $target, which this installer did not write"
		else
			say "$target is a hook this installer did not write; leaving it alone."
			say "Re-run with --force to replace it."
			exit 1
		fi
	fi
	tmp="$target.tmp.$$"
	cat >"$tmp" <<EOF
#!/usr/bin/env sh
# codetracer portable git-hook layer -- $marker
# Runs the $hook checks nix/pre-commit.nix declares, without Nix. All logic lives
# in the checkout (ci/dev/portable-pre-commit.sh), so this file never goes stale.
root=\$(git rev-parse --show-toplevel) || exit 1
entry="\$root/ci/dev/portable-pre-commit.sh"
if [ ! -f "\$entry" ]; then
	echo "codetracer pre-commit: \$entry does not exist in this commit, so the $hook" >&2
	echo "codetracer pre-commit: checks CANNOT RUN and the $hook FAILS. The commit checked out" >&2
	echo "codetracer pre-commit: predates the portable hook layer: rebase it onto dev." >&2
	exit 1
fi
exec sh "\$entry" $hook "\$(dirname -- "\$0")" "\$@"
EOF
	chmod +x "$tmp"
	mv -f "$tmp" "$target"
	say "installed $target"
done

say "checks come from $repo_root/nix/pre-commit.nix; see what this host can run with:"
say "  python ci/dev/portable-pre-commit.py doctor"
