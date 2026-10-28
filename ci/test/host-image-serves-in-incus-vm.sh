#!/usr/bin/env bash
#
# `ct host` SERVES FROM INSIDE A CONTAINER, graded where no Incus daemon exists:
# publish `ct host`'s image and run `ci/test/host-image-serves-in-a-container.sh`
# against a real Incus daemon that this script boots, in a NixOS VM.
#
# ## Why this file exists
#
# The gate needs an Incus daemon with a managed bridge and the image published
# into it. No CI runner class hands a job one: the ephemeral Linux runners are
# themselves Incus containers and offer Docker and `/dev/kvm`, not Incus. So the
# gate sat in `shell-gate-coverage.known-dark.txt`, and the seam it closes
# (WD2: the server inside the container, reached from outside it) was graded by
# hand only. `/dev/kvm` is enough to boot an Incus host, and
# `nix/packages/incus-vm.nix` is that host — its header says why a VM rather
# than an OCI-runtime variant of the gate, which would test a different start-up
# path from the one the gate's three defects were found in.
#
# ## What runs where
#
# OUTSIDE (the default): build the two inputs this repository owns with the
# host's nix — `packages.codetracer-host-image` and the VM driver — take the
# session substrate's CLI from the caller (see "the resolver" below), then boot
# the VM with this checkout shared at `/repo` and re-enter this script there
# with `--inside-vm`. The host's store is the VM's store, so the store paths
# built here are valid arguments inside.
#
# INSIDE (`--inside-vm`, root on the VM's Incus host): the substrate is
# provisioned by its own `sessionctl image build`, then the operator's two
# steps, unchanged — the publication into the substrate's project, which
# finishes only when `sessionctl image-resolve` names the image, and the gate.
#
# ## THE RESOLVER IS SUPPLIED, NEVER FETCHED
#
# `ci/publish-host-image.sh` confirms its import with `sessionctl
# image-resolve`, so this gate needs that CLI. It does **not** build it: this
# repository is public, and a public tree must not name, pin or fetch a
# non-public sibling — nor can it, for the audience a public tree has, since
# the fetch would need credentials an outside contributor or a fork does not
# have. So the binary is an INPUT. Give it as a path, or as a flake reference
# through the environment, which is where a deployment that has one keeps it
# (in CI, a masked secret rather than a tracked file). With neither, the gate
# refuses and says so; it never guesses a source.
#
# Usage:  bash ci/test/host-image-serves-in-incus-vm.sh
#           [--oci-archive PATH]   use this codetracer-host-image, do not build
#           [--sessionctl PATH]    use this sessionctl binary, do not build
#           [--keep-work]          keep the work directory (VM state, out-links)
# Env:    CT_SESSIONCTL           same as `--sessionctl`
#         CT_SESSIONCTL_FLAKE     a flake reference whose `#sessionctl` output
#                                 is built when no path was given. Pin a
#                                 revision in the value, not a branch, so this
#                                 gate's verdict changes only when codetracer
#                                 changes.
# Needs:  Linux, `nix`, a readable/writable `/dev/kvm` (CI: a runner labelled
#         `kvm`), and a `sessionctl` from one of the two inputs above.
set -euo pipefail

# `-` and no `:` — see the alias rules in `ci/publish-host-image.sh`.
alias_name="codetracer-host-ci"

oci_archive=""
sessionctl_bin="${CT_SESSIONCTL:-}"
sessionctl_flake="${CT_SESSIONCTL_FLAKE:-}"
keep_work=0
inside_vm=0
while [ $# -gt 0 ]; do
	case "$1" in
	--oci-archive)
		oci_archive="${2:-}"
		shift 2
		;;
	--sessionctl)
		sessionctl_bin="${2:-}"
		shift 2
		;;
	--keep-work)
		keep_work=1
		shift
		;;
	--inside-vm)
		inside_vm=1
		shift
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

if [ "${inside_vm}" -eq 1 ]; then
	# Both are handed in by the outer half; nothing here may build.
	if [ -z "${oci_archive}" ] || [ -z "${sessionctl_bin}" ]; then
		echo "--inside-vm needs --oci-archive and --sessionctl" >&2
		exit 2
	fi
	# A FRESH DAEMON IS NOT A SUBSTRATE HOST YET. The substrate keeps its
	# sessions and their images in an Incus project of its own, and it creates
	# that project itself (`ensureProject`, reached from `sessionctl image
	# build`, which also imports the substrate's own base image). The publisher
	# refuses a daemon without the project, so the substrate is provisioned
	# first, by its own CLI — nothing here creates the project by hand, which
	# would be a substrate configured by someone other than the substrate.
	# Its state lives in a scratch directory: this VM is thrown away after.
	substrate_dir="$(mktemp -d)"
	mkdir -p "${substrate_dir}/state" "${substrate_dir}/data"
	echo "==> inside the Incus VM: provisioning the session substrate"
	ISONIM_SESSION_STATE_DIR="${substrate_dir}/state" \
		ISONIM_DEV_DATA_DIR="${substrate_dir}/data" \
		"${sessionctl_bin}" image build
	echo
	echo "==> inside the Incus VM: publishing ${alias_name}"
	bash ci/publish-host-image.sh --oci-archive "${oci_archive}" \
		--sessionctl "${sessionctl_bin}" --alias "${alias_name}"
	echo
	echo "==> inside the Incus VM: the gate"
	bash ci/test/host-image-serves-in-a-container.sh --alias "${alias_name}"
	exit $?
fi

if [ "$(uname -s)" != "Linux" ]; then
	echo "host-image-serves-in-incus-vm: Incus and its VM are Linux-only" >&2
	exit 2
fi
command -v nix >/dev/null 2>&1 || {
	echo "host-image-serves-in-incus-vm: nix is not on PATH" >&2
	exit 1
}
# Refused up front rather than left to qemu: without KVM the test driver falls
# back to TCG, which boots, and then times out somewhere that does not say why.
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo "host-image-serves-in-incus-vm: /dev/kvm is not usable by $(id -un)" >&2
	echo "  remedy: run on a KVM-capable host (CI: [self-hosted, linux, x64, kvm])" >&2
	exit 1
fi
# BEFORE THE IMAGE BUILD, which is the expensive step (median ~9 minutes warm,
# tens of minutes on a cold store). A missing resolver is a configuration fact
# knowable in no time at all, and discovering it after the build wastes the
# whole job.
if [ -z "${sessionctl_bin}" ] && [ -z "${sessionctl_flake}" ]; then
	echo "host-image-serves-in-incus-vm: no sessionctl was supplied" >&2
	echo "  remedy: pass --sessionctl PATH, or set CT_SESSIONCTL to a built" >&2
	echo "          binary, or set CT_SESSIONCTL_FLAKE to a flake reference" >&2
	echo "          whose '#sessionctl' output this may build. In CI that" >&2
	echo "          value is a masked secret, not a tracked file." >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-incus-vm-XXXXXX")"
cleanup() {
	[ "${keep_work}" -eq 1 ] && {
		echo "kept ${work}"
		return 0
	}
	rm -rf "${work}" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

# Out-links in the work directory, not `--no-link`: they are the GC roots that
# keep these store paths alive while the VM, which reads them from the shared
# store, is using them.
if [ -z "${oci_archive}" ]; then
	echo "==> building packages.codetracer-host-image"
	oci_archive="$(nix build --out-link "${work}/host-image" --print-out-paths \
		'.?submodules=1#codetracer-host-image')"
fi
if [ -z "${sessionctl_bin}" ]; then
	# A path was not given, so the reference is the source. That it is
	# non-empty was settled before the image build above; this cannot be
	# reached with both unset.
	echo "==> building sessionctl from the configured reference"
	sessionctl_bin="$(nix build --out-link "${work}/sessionctl" --print-out-paths \
		"${sessionctl_flake}#sessionctl")/bin/sessionctl"
fi
echo "==> building the Incus VM"
vm_driver="$(nix build --out-link "${work}/incus-vm" --print-out-paths \
	'.#codetracer-incus-vm')/bin/nixos-test-driver"

for input in "${oci_archive}" "${sessionctl_bin}"; do
	case "${input}" in
	/nix/store/*) ;;
	*)
		# The VM sees the host's store and the shared checkout, nothing else.
		echo "host-image-serves-in-incus-vm: ${input} is not a store path, so the VM cannot see it" >&2
		exit 2
		;;
	esac
done

echo "==> booting the Incus VM"
mkdir -p "${work}/vm"
# The driver keeps its VM state under TMPDIR; the work directory makes that
# state go away with everything else unless `--keep-work`.
TMPDIR="${work}/vm" \
	CT_INCUS_VM_REPO="${repo_root}" \
	CT_INCUS_VM_COMMAND="bash ci/test/host-image-serves-in-incus-vm.sh --inside-vm --oci-archive '${oci_archive}' --sessionctl '${sessionctl_bin}'" \
	"${vm_driver}"
