#!/usr/bin/env sh
#
# portable-pre-commit.sh -- the git-hook entry point of the non-Nix hook layer.
#
#   portable-pre-commit.sh <hook-type> <hook-dir> [git hook args...]
#
# Called by the shim ci/dev/install-portable-git-hooks.sh writes into the hooks
# directory. The shim holds no logic, so an installed hook cannot go stale: what
# runs is whatever this commit's ci/dev/portable-pre-commit.py says.
#
# Its one job is finding a working Python 3 and handing over. It exists as
# shell rather than as a Python shebang because on Windows `python3` is often
# the Microsoft Store alias -- an executable that prints "Python was not found"
# and exits 9009 -- and a hook that dies on that says nothing useful. Each
# candidate is therefore RUN, not merely looked up.
#
# stdin is passed straight through: the pre-push hook's ref list arrives on it.
set -eu

if [ "$#" -lt 2 ]; then
	echo "codetracer pre-commit: usage: $0 <hook-type> <hook-dir> [args...]" >&2
	exit 2
fi
hook_type=$1
hook_dir=$2
shift 2

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

python=
for candidate in python3 python; do
	if command -v "$candidate" >/dev/null 2>&1 &&
		"$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
			>/dev/null 2>&1; then
		python=$candidate
		break
	fi
done
if [ -z "$python" ]; then
	echo "codetracer pre-commit: no working Python >= 3.9 on PATH, so the $hook_type" >&2
	echo "codetracer pre-commit: checks from nix/pre-commit.nix CANNOT RUN and the $hook_type FAILS." >&2
	echo "codetracer pre-commit:   remedy (Windows): scoop install python" >&2
	echo "codetracer pre-commit:   (a 'python3' that opens the Microsoft Store is not a Python)" >&2
	exit 1
fi

# Python on Windows cannot open an MSYS path such as /m/work/.git/hooks. Git for
# Windows' `pwd -W` prints the native spelling; everywhere else it is not an
# option and plain `pwd` is already native.
hook_dir=$(CDPATH='' cd -- "$hook_dir" && { pwd -W 2>/dev/null || pwd; })
script=$(CDPATH='' cd -- "$here" && { pwd -W 2>/dev/null || pwd; })/portable-pre-commit.py

exec "$python" "$script" hook "$hook_type" --hook-dir "$hook_dir" -- "$@"
