#!/usr/bin/env bash
# =============================================================================
# Fail early, and by name, when the host cannot give `tup` its FUSE mount.
#
# `tup` tracks dependencies by mounting a FUSE filesystem on `.tup/mnt` and
# watching what the build reads through it. It does that through libfuse3,
# which does not mount the filesystem itself: unless the caller is already
# privileged enough for a direct `mount(2)`, it spawns a small setuid helper,
# `fusermount3`, and receives the `/dev/fuse` file descriptor back over a
# socket. See libfuse's `lib/mount.c` (`fuse_mount_sys` first, then
# `fuse_mount_fusermount`): https://github.com/libfuse/libfuse
#
# libfuse looks for that helper in TWO places, in order, and both matter:
#
#   1. An absolute path baked into the binary. nixpkgs patches libfuse to try
#      `/run/wrappers/bin/fusermount3`, a NixOS `security.wrappers` setuid
#      wrapper, via `posix_spawn` -- no PATH search, by design.
#   2. If that fails, the BARE name, via `posix_spawnp("fusermount3", ...)`.
#      No slash, so PATH *is* searched.
#
# Both call sites are visible in the library:
#
#   $ objdump -d --disassemble=fusermount_posix_spawn .../libfuse3.so.4
#     ... lea 0x...(%rip),%rsi   # .rodata 0x2bde1 "/run/wrappers/bin/fusermount3"
#     ... call posix_spawn@plt
#     ... lea 0x...(%rip),%rsi   # .rodata 0x2bdf3 "fusermount3"
#     ... call posix_spawnp@plt
#
# tup's own literal has the same shape. nixpkgs' `fusermount-setuid.patch` is
# headed "Tup needs a setuid fusermount which may be outside $PATH" and does
# `access("/run/wrappers/bin/fusermount3", X_OK) == 0 ? absolute : bare name`.
#
# So a `fuse3` entry on a dev shell's PATH is NOT inert -- it is exactly what
# satisfies step 2, and it is why `nix/shells/ci-base.nix` lists it. What no
# devShell can do is make that helper SETUID, and unprivileged FUSE mounting
# needs it to be. The store copy therefore turns
#
#   posix_spawn(p)() for fusermount3 failed: No such file or directory
#   tup error: Timed out waiting for the FUSE file-system to be ready.
#   tup error: Unable to mount FUSE on .tup/mnt
#
# -- which reads as "tup is broken" -- into `mount failed: Operation not
# permitted`, which names the real requirement. Better, but still not a mount.
#
# This check accepts EITHER resolution, because either is enough for libfuse to
# find a helper. Requiring only the baked path would reject every non-NixOS
# Linux, where /run/wrappers does not exist and the distribution ships a setuid
# /usr/bin/fusermount3 that step 2 finds -- i.e. it would block builds that
# work today.
#
# So this check exists to name the real requirement at the point where it is
# still cheap to act on, instead of letting a missing host capability be
# mistaken for a build failure. It does not, and cannot, provide the helper.
#
# Run: bash scripts/require-fuse-mount-helper.sh [path-to-tup]
# Lane: called by scripts/build-once.sh before its first `tup` invocation, so
#       it runs in every job that builds the frontend through tup --
#       `cross-process-linux`, `dev-build` and local `just build-once`.
# =============================================================================
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
	# tup's FUSE path is Linux-only; macOS/Windows build through reprobuild.
	exit 0
fi

# /dev/fuse comes first: without it there is nothing for any helper to open,
# and the helper's own diagnostic ("fuse device not found") is easy to read as
# a tup problem. Unprivileged containers do not get this device unless the
# supervisor is told to add it -- on the ephemeral Incus runner class it is
# not added by default.
if [ ! -c /dev/fuse ]; then
	cat >&2 <<'EOF'
Cannot start the tup build: /dev/fuse is not present.

tup tracks dependencies by mounting a FUSE filesystem on .tup/mnt, which
requires the /dev/fuse character device. A kernel without the `fuse` module,
or a container that was not given the device, has no way to provide it.

Fix it on the host:
  * bare metal / VM: load the module (`modprobe fuse`), or build a kernel
    with CONFIG_FUSE_FS.
  * containers: expose the device to the guest. Under Incus/LXD that is a
    `unix-char` device with source=/dev/fuse; under Docker it is
    `--device /dev/fuse`. For the ephemeral CI runners this belongs in the
    runner image / container recipe, not in this repository.
EOF
	exit 1
fi

tup_bin="${1:-${TUP:-tup}}"
if ! command -v "$tup_bin" >/dev/null 2>&1; then
	echo "scripts/require-fuse-mount-helper.sh: no '$tup_bin' on PATH." >&2
	exit 1
fi
tup_bin="$(command -v "$tup_bin")"

# Resolution 1: the absolute paths baked into the binaries, read back out of
# them rather than hardcoded here where they could drift from nixpkgs. Look in
# libfuse too, not only tup: libfuse is what performs the MOUNT spawn, while
# tup's own copy of the literal is only for its unmount call.
# `|| true`: ldd exits non-zero when handed something that is not a dynamic
# executable (a wrapper script, say), and `set -o pipefail` would otherwise
# turn that into an abort here rather than the diagnostic below.
fuse_lib="$(ldd "$tup_bin" 2>/dev/null | awk '/libfuse3/ { print $3; exit }' || true)"
baked_paths="$(
	{
		grep -a -o -E '/[[:alnum:]_./+-]*/fusermount3' "$tup_bin" 2>/dev/null || true
		if [ -n "$fuse_lib" ] && [ -e "$fuse_lib" ]; then
			grep -a -o -E '/[[:alnum:]_./+-]*/fusermount3' "$fuse_lib" 2>/dev/null || true
		fi
	} | sort -u
)"

# Every baked path is a candidate, not just the first one in file order: a
# binary may carry several and only one of them need be usable.
baked_helper=""
for candidate in $baked_paths; do
	if [ -x "$candidate" ]; then
		baked_helper="$candidate"
		break
	fi
done

# Resolution 2: the bare name on PATH, which is what `posix_spawnp` finds.
path_helper="$(command -v fusermount3 2>/dev/null || true)"

if [ -n "$baked_helper" ] || [ -n "$path_helper" ]; then
	exit 0
fi

{
	echo "Cannot start the tup build: no FUSE mount helper can be found."
	echo
	echo "  tup binary:  $tup_bin"
	if [ -n "$fuse_lib" ]; then
		echo "  libfuse:     $fuse_lib"
	fi
	if [ -n "$baked_paths" ]; then
		echo "  compiled-in helper paths, none of them executable:"
		for candidate in $baked_paths; do
			echo "    $candidate"
		done
	else
		echo "  no compiled-in helper path found in either binary"
	fi
	echo "  'fusermount3' on PATH: not found"
	cat <<'EOF'

tup mounts a FUSE filesystem on .tup/mnt to observe what the build reads.
libfuse gets the /dev/fuse descriptor by spawning `fusermount3` -- first at
the absolute path compiled into it, then, failing that, by bare name through
PATH. Neither resolved here, so the mount cannot even be attempted.

Adding `fuse3` to a Nix dev shell satisfies the second of those, and
`nix/shells/ci-base.nix` does exactly that. What it cannot do is make the
helper SETUID, which is what an unprivileged process needs in order to mount
FUSE at all -- so on a host without the setuid wrapper this check passes and
the build then fails with `mount failed: Operation not permitted`. That is a
different, and honest, failure.

Fix it on the host:
  * NixOS: enable the setuid wrapper in the system configuration, e.g.
      programs.fuse.userAllowOther = true;
    or, explicitly,
      security.wrappers.fusermount3 = {
        source = "${pkgs.fuse3}/bin/fusermount3";
        owner = "root"; group = "root"; setuid = true;
      };
    For the ephemeral CI runners this belongs in the runner image, not in
    this repository.
  * Other distributions: install the distribution's 'fuse3' package, which
    ships a setuid /usr/bin/fusermount3.
  * Containers additionally need /dev/fuse exposed to the guest.
EOF
} >&2
exit 1
