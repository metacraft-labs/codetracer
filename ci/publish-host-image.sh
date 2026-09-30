#!/usr/bin/env bash
# Publish `ct host`'s OCI image into an Incus daemon's image store, and CONFIRM
# it is resolvable before anything depends on it — WD2.
#
# ## Why a conversion and not `incus image import` on the OCI tarball
#
# `packages.codetracer-host-image` is a `dockerTools.buildLayeredImage`, which
# is a docker-archive: `manifest.json`, a config blob and one tar per layer.
# `incus image import` (6.0.6) takes an Incus UNIFIED tarball — `metadata.yaml`
# plus `rootfs/` — or a metadata/rootfs pair. It does not read a docker
# archive, and the failure is not obvious: it reports a metadata error about a
# file the archive legitimately does not have.
#
# The other route Incus offers is `incus image copy docker:<ref> local:`, which
# needs the image in a registry the daemon can reach. That is the right route
# for a deployment that has one, and it is the WRONG requirement to impose
# here: §8a of the substrate spec makes "running offline" a supported
# configuration — locally built images, pools of depth 1 — and a publication
# step that needed a registry would make an offline substrate unable to run the
# product this campaign is about.
#
# So the layers are applied, in manifest order, into a `rootfs/` beside a
# `metadata.yaml`, and the result is packed the way
# `isonim-platform/session/src/image.nim` packs its own: one archive format,
# sorted names, zeroed owners, a constant mtime and `gzip -n`. Same recipe
# rather than a similar one, because the substrate's `sha256File` is what
# checks the fingerprint and a differently-packed tarball would content-address
# differently for a reason that has nothing to do with its contents.
#
# ## The confirmation is the point of the script
#
# `sessionctl image-resolve --reference REF` answers "" for a reference the
# daemon does not have, and `incus.resolveImage`'s own header says why that
# matters: a session started from the wrong environment LOOKS like a working
# session and fails in the user's editor rather than here. So this script does
# not finish on a successful import — it finishes when the substrate's own
# resolver can name the image, and exits non-zero otherwise.
#
#   ci/publish-host-image.sh [--alias NAME] [--sessionctl PATH] [--keep-work]
#
# Everything it needs is discovered: `nix`, `incus` and (for the confirmation)
# a `sessionctl` on PATH or named with `--sessionctl`.
set -euo pipefail

alias_name=""
sessionctl_bin="${SESSIONCTL:-sessionctl}"
keep_work=0

while [ $# -gt 0 ]; do
	case "$1" in
	--alias)
		alias_name="${2:-}"
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
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

for tool in nix incus tar; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "publish-host-image: ${tool} is not on PATH" >&2
		exit 1
	}
done

if [ -z "${alias_name}" ]; then
	# The revision, so two builds of two commits are two images rather than one
	# name that silently moves. A dirty tree gets `-dirty`, for the same reason
	# the deploy workflow refuses an abbreviated commit: a name that cannot be
	# traced back to bytes is a name nothing can check.
	rev="$(git rev-parse HEAD)"
	if [ -n "$(git status --porcelain)" ]; then rev="${rev}-dirty"; fi
	alias_name="codetracer-host:${rev}"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-host-image-XXXXXX")"
cleanup() { [ "${keep_work}" -eq 1 ] || rm -rf "${work}"; }
trap cleanup EXIT

echo "==> building packages.codetracer-host-image"
# `?submodules=1` and both trace-format overrides are this flake's documented
# invocation; without them the build resolves a different pair of FFI inputs,
# and the two must move together or not at all.
oci_tar="$(nix build --no-link --print-out-paths '.?submodules=1#codetracer-host-image')"
echo "    ${oci_tar}"

echo "==> unpacking the docker archive"
mkdir -p "${work}/oci"
tar -xf "${oci_tar}" -C "${work}/oci"

manifest="${work}/oci/manifest.json"
[ -f "${manifest}" ] || {
	echo "publish-host-image: ${oci_tar} carries no manifest.json; it is not a docker archive" >&2
	exit 1
}

echo "==> applying layers in manifest order"
rootfs="${work}/unified/rootfs"
mkdir -p "${rootfs}"
layers="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))[0]["Layers"]))' "${manifest}")"
layer_count=0
while IFS= read -r layer; do
	[ -n "${layer}" ] || continue
	# ORDER MATTERS AND OVERWRITING IS THE POINT. A later layer replaces a file
	# an earlier one wrote; extracting them in any other order, or with
	# `--keep-old-files`, produces a rootfs that is a mixture of two builds.
	tar -xf "${work}/oci/${layer}" -C "${rootfs}"
	layer_count=$((layer_count + 1))
done <<<"${layers}"
echo "    ${layer_count} layer(s)"

# `.wh.` whiteouts: a layer deletes a file by adding a marker rather than by
# removing it, and tar knows nothing about that convention. Left in place they
# are visible files with odd names; the file they were meant to delete also
# survives, which is the half that matters.
find "${rootfs}" -name '.wh.*' -print0 | while IFS= read -r -d '' marker; do
	victim="$(dirname "${marker}")/$(basename "${marker}" | sed 's/^\.wh\.//')"
	rm -rf -- "${victim}" "${marker}"
done

echo "==> writing metadata.yaml"
# The same four keys `isonim-platform/session/src/image.nim` writes, and the
# same constant epoch: the tarball is content-addressed, so a build timestamp
# in it would give two identical images two fingerprints.
cat >"${work}/unified/metadata.yaml" <<YAML
architecture: x86_64
creation_date: 1
properties:
  description: CodeTracer host (ct host)
  os: nixos
  release: codetracer
YAML

echo "==> packing the unified tarball"
# Byte-for-byte the recipe `session/src/image.nim`'s `packImage` uses. Not a
# similar one: the substrate's `sha256File` is what checks the fingerprint, and
# a differently-packed archive content-addresses differently for reasons that
# have nothing to do with what is in it.
unified="${work}/codetracer-host.tar.gz"
(
	cd "${work}/unified"
	find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort >"${work}/filelist"
	tar --format=gnu --sort=name \
		--owner=0 --group=0 --numeric-owner --mtime='@1' \
		--no-recursion -T "${work}/filelist" -cf - |
		gzip -n -9 >"${unified}"
)
echo "    $(wc -c <"${unified}") bytes, $(wc -l <"${work}/filelist") entries"

echo "==> importing as ${alias_name}"
# `--reuse` so republishing the same alias replaces it rather than failing.
# A publication that refused on its second run would push every operator
# towards deleting by hand, which is the step that gets skipped.
incus image import "${unified}" --alias "${alias_name}" --reuse

echo "==> confirming with sessionctl image-resolve"
# THE STEP THIS SCRIPT EXISTS FOR. An import that succeeded and a reference the
# substrate cannot resolve are not the same thing — a project pointed at an
# unresolvable image gets a session built from the substrate's own base image,
# which looks like a working session and fails in the user's editor.
if ! command -v "${sessionctl_bin}" >/dev/null 2>&1 && [ ! -x "${sessionctl_bin}" ]; then
	echo "publish-host-image: no sessionctl (${sessionctl_bin}); the image was imported but NOT confirmed" >&2
	echo "  remedy: pass --sessionctl PATH, or set SESSIONCTL" >&2
	exit 1
fi

resolved="$("${sessionctl_bin}" image-resolve --reference "${alias_name}" 2>/dev/null || true)"
fingerprint="$(printf '%s' "${resolved}" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("fingerprint", ""))
except Exception:
    print("")' || true)"

if [ -z "${fingerprint}" ]; then
	echo "publish-host-image: the daemon accepted the import and the substrate cannot resolve '${alias_name}'" >&2
	echo "  sessionctl answered: ${resolved}" >&2
	echo "  a project pointed at this reference would get the substrate's base image instead" >&2
	exit 1
fi

echo "published ${alias_name} -> ${fingerprint}"
printf '{"alias":"%s","fingerprint":"%s","layers":%s}\n' \
	"${alias_name}" "${fingerprint}" "${layer_count}"
