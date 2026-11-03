#!/usr/bin/env bash
# gpui-shim-stage.sh — put a shim arm at the live path for a run, and put back
# what was there. Sourced by the GPUI capture lanes that select a shim by file
# substitution; it defines functions and touches nothing until one is called.
# Functions print to stderr and return non-zero. Only the two trap handlers exit.
#
#   gpui_shim_install_traps            before anything can be staged
#   gpui_shim_stage <live> <arm> ||    fail "...", once per arm
#   gpui_shim_restore ||               fail "...", where a lane restores early
#
# WHY A LANE SUBSTITUTES A FILE, AND WHY IT NEVER COPIES OVER ONE. isonim-gpui's
# bindings bake the shim's absolute path into a `{.dynlib.}` pragma, so an arm is
# selected by putting its bytes at that path. `cp` writes through an existing
# inode, and that does a different damage on each host:
#   - On Linux cargo uplifts `target/debug/libgpui_nim_shim.so` as a HARDLINK to
#     `target/debug/deps/…`, so a `cp` onto the live path rewrites cargo's own
#     cached output. Cargo judges freshness by fingerprint, not by bytes, so the
#     next `cargo build` reports the unit fresh and re-uplifts the arm's bytes.
#     Measured 2026-10-18: after a capture, `isonim-gpui`'s `plat37-shims` staged
#     a "featureless" shim byte-identical to the headless one (341,153,248 bytes;
#     a genuine featureless link is 8,083,520).
#   - On macOS cargo copies the uplifted file instead
#     (https://github.com/rust-lang/cargo/issues/10060, measured with cargo 1.96
#     on 2026-11-01), so `deps/` is out of reach. The risk there is the code
#     signature: macOS caches one per file, so an app loading new bytes from an
#     inode that was mapped before dies with SIGKILL (Code Signature Invalid),
#     which reads as a front-end crash. Measured 2026-11-01.
#
# So the first arm of a run moves the live shim aside, which keeps cargo's inode
# and gives the arm a new one. A later arm unlinks the previous arm, because
# copying over it would rewrite what its app had mapped. The restore moves the
# original back, so the hardlink survives the run. A backup made by copying
# would restore the bytes on a new inode and leave the hardlink broken. A `cp -f`
# also succeeds where the move fails, as in a read-only directory, so every step
# before it is checked.
#
# ON DISK, SO THAT A KILLED RUN CAN BE RECOGNISED. Both names belong to the path
# and to no lane, because the run after a kill may be a different lane:
#   <live>.gpui-lane-backup       the original. If it exists when a run starts,
#                                 an earlier run was killed, and the live path
#                                 holds that run's arm. Moving that arm over the
#                                 backup is how the original used to be lost, so
#                                 the backup is kept and the arm is unlinked.
#   <live>.gpui-lane-no-original  the run found no live shim, so the arm is
#                                 removed on exit. Without it, the run after a
#                                 kill would mistake the arm for an original.
#
#   <live>.plat35-backup, .plat37-backup, .plat37macos-backup, .plat38-backup,
#   .plat42-backup, .plat44-backup
#                                 the same original, left by a lane killed before
#                                 the lanes shared this file. The first stage of a
#                                 run moves it to the shared name. Two of them
#                                 cannot both be the original (the second was a
#                                 killed run's arm), and the files cannot say
#                                 which is which, so a stage refuses them and
#                                 names both.
#
# A failed swap stops the lane, through the caller's `fail`, and a failed restore
# fails it. The backup or the marker then stays, so a later run can still finish
# the job.
#
# KNOWN LIMIT: THE FILES SAY WHAT WAS TRUE WHEN THE RUN WAS KILLED. If cargo
# rebuilds between the kill and the re-run, the kept backup is the OLDER cargo
# output and the lane restores it (and a kept marker removes the new build). The
# next `cargo build` re-uplifts the current one. That repair was measured on m3
# (Darwin arm64) only. It was not measured on Linux, where `deps/` keeps cargo's
# bytes. A lane cannot detect this case: cargo's new file and a stale arm are both
# just a file at the live path.
#
# Lanes that share a live path must not run concurrently. They never could: a
# second lane's arm replaces the first's under its running app.

GPUI_SHIM_BACKUP_SUFFIX=".gpui-lane-backup"
GPUI_SHIM_MARKER_SUFFIX=".gpui-lane-no-original"
# The names each lane used before it sourced this file. See the header.
GPUI_SHIM_OLD_BACKUP_SUFFIXES=".plat35-backup .plat37-backup .plat37macos-backup .plat38-backup .plat42-backup .plat44-backup"

# Assigned and not defaulted, so that nothing in the environment can claim that
# this run staged. All three belong to one run, and none of them leaves it.
GPUI_SHIM_LIVE=""
# This run reached `gpui_shim_stage`, so its restore has work to consider. A run
# that exits on a prerequisite never sets it, and must not touch another run's
# backup.
GPUI_SHIM_RESTORE_PENDING=0
# The original is accounted for, so the live path holds only this run's arm. It
# is separate from the flag above because a first call that failed its move must
# still restore, and must not unlink the original as a "previous arm".
GPUI_SHIM_ARM_OWNS_LIVE=0

# gpui_shim_stage <live> <arm> — make <arm>'s bytes the shim at <live>, on a new
# inode. Re-entrant: each later call in a run replaces the previous arm.
gpui_shim_stage() {
	local live="$1" arm="$2"
	local backup="${live}${GPUI_SHIM_BACKUP_SUFFIX}"
	local marker="${live}${GPUI_SHIM_MARKER_SUFFIX}"
	if [ "${GPUI_SHIM_ARM_OWNS_LIVE}" != 1 ]; then
		gpui_shim_adopt_old_backup "${live}" || return 1
	fi
	GPUI_SHIM_LIVE="${live}"
	GPUI_SHIM_RESTORE_PENDING=1

	if [ "${GPUI_SHIM_ARM_OWNS_LIVE}" = 1 ]; then
		rm -f "${live}" || {
			echo "the previous arm at ${live} could not be removed, so the next one was not staged" >&2
			return 1
		}
	elif [ -f "${backup}" ]; then
		# An earlier run was killed. What is at the live path is its arm, or a build
		# that cargo hardlinked to `deps/`, so it is unlinked and never copied over.
		rm -f "${live}" || {
			echo "the stale shim at ${live} could not be removed, so nothing was staged; the original stays at ${backup}" >&2
			return 1
		}
		echo "kept the original shim at ${backup}, from a run that did not finish"
	elif [ -f "${marker}" ]; then
		rm -f "${live}" || {
			echo "the stale shim at ${live} could not be removed, so nothing was staged" >&2
			return 1
		}
	elif [ -f "${live}" ]; then
		mv -f "${live}" "${backup}" || {
			echo "the live shim could not be moved aside, so nothing was staged" >&2
			return 1
		}
	else
		touch "${marker}" || {
			echo "${marker} could not be created, so nothing was staged" >&2
			return 1
		}
	fi
	GPUI_SHIM_ARM_OWNS_LIVE=1

	cp -f "${arm}" "${live}" || {
		echo "${arm} could not be staged at ${live}" >&2
		return 1
	}
}

# gpui_shim_adopt_old_backup <live> — move a backup left under an old per-lane
# name to the shared one. Called before this run claims anything, so a refusal
# leaves every file as it was and the restore has nothing to undo.
gpui_shim_adopt_old_backup() {
	local live="$1" suffix found=""
	local backup="${live}${GPUI_SHIM_BACKUP_SUFFIX}"
	for suffix in ${GPUI_SHIM_OLD_BACKUP_SUFFIXES}; do
		[ -f "${live}${suffix}" ] && found="${found} ${live}${suffix}"
	done
	[ -n "${found}" ] || return 0
	if [ -f "${backup}" ]; then
		found="${backup}${found}"
	else
		found="${found# }"
	fi
	case "${found}" in
	*" "*)
		echo "more than one backup of ${live} exists, and only one can be the original:" >&2
		echo "  ${found}" >&2
		echo "  nothing was staged. Keep the original at ${live}, delete the others, or rebuild the shim with cargo." >&2
		return 1
		;;
	esac
	mv -f "${found}" "${backup}" || {
		echo "the old backup ${found} could not be moved to ${backup}, so nothing was staged" >&2
		return 1
	}
}

# gpui_shim_restore — put back what this run found. Does nothing unless this run
# reached `gpui_shim_stage`, and nothing the second time. A failure leaves the
# state as it was, so the EXIT trap retries a restore that a lane tried early.
gpui_shim_restore() {
	[ "${GPUI_SHIM_RESTORE_PENDING}" = 1 ] || return 0
	local live="${GPUI_SHIM_LIVE}"
	local backup="${live}${GPUI_SHIM_BACKUP_SUFFIX}"
	local marker="${live}${GPUI_SHIM_MARKER_SUFFIX}"

	# Neither file: the first step failed, and the live path was not touched.
	if [ -f "${backup}" ]; then
		mv -f "${backup}" "${live}" || {
			echo "failed to restore ${live}; backup remains at ${backup}" >&2
			return 1
		}
		echo "restored ${live}"
	elif [ -f "${marker}" ]; then
		rm -f "${live}" || {
			echo "failed to remove the staged shim at ${live}; none existed before this run" >&2
			return 1
		}
		rm -f "${marker}" || {
			echo "failed to remove ${marker}; the next run will take the live path as stale" >&2
			return 1
		}
		echo "removed the staged shim at ${live}; none existed before this run"
	fi
	GPUI_SHIM_RESTORE_PENDING=0
	GPUI_SHIM_ARM_OWNS_LIVE=0
}

# EXIT handler: restore, and let a failed restore fail the lane. `exit` is what
# makes that possible: bash ignores what a trap handler returns, so a plain
# `trap restore EXIT` cannot change the status. A status that is already non-zero
# is the lane's own verdict and is kept. Not for explicit calls, because it reads
# `$?` and exits.
#
# Further signals are ignored so that a second Ctrl-C cannot stop the restore
# halfway through.
gpui_shim_exit_trap() {
	local rc=$?
	trap '' INT TERM
	gpui_shim_restore || {
		[ "${rc}" -ne 0 ] || rc=1
	}
	exit "${rc}"
}

# INT and TERM exit, with the shell's usual 128+N, through the lane's EXIT trap.
# A signal trap that only restored would return, and the lane would run on with
# its arm gone from the live path.
#
# Measured on bash 3.2.57 and 5.3.9: with these traps a signal is acted on when
# the foreground child returns, and the restore follows it. Without them SIGTERM
# ends bash at once and restores under an app that is still running, and SIGINT
# to the lane alone is only acted on if the child also died of it.
gpui_shim_trap_signals() {
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# For a lane with nothing else to do on exit. The macOS capture lane has its own
# EXIT trap, which calls `gpui_shim_restore`, and takes only the signal traps.
gpui_shim_install_traps() {
	trap 'gpui_shim_exit_trap' EXIT
	gpui_shim_trap_signals
}
