#!/usr/bin/env bash
#
# shellcheck disable=SC2016
#
# `ct host` SERVES FROM INSIDE A CONTAINER, REACHED FROM OUTSIDE IT — the join
# WD1a, WD1c and WD2 were each half of, and the seam
# `ci/SEAM-REGISTER.md` was written to name.
#
# ## Why this is the test and not six smaller ones
#
# Every part had its own green check and the join had none. The image built, the
# publication imported, `sessionctl image-resolve` RESOLVED it, `ct host`'s port
# resolution had 23 unit assertions and its URL line had 7 — and starting the
# thing failed three times for three unrelated reasons, each invisible to all of
# them:
#
#   1. `codetracer-host`'s wrapper had dropped `LD_LIBRARY_PATH`, so
#      `.ct-wrapped` could not `dlopen` libcrypto and `ct` did not run at all.
#   2. The converted image had no `/sbin/init`, and then an init whose route
#      test used `grep` — absent here — so it reported `no-lease` while the
#      lease was in `dhcpcd.log`.
#   3. `dockerTools` ships no `/etc/passwd`, because an OCI runtime never asks
#      who it is. node's `os.userInfo()` does, three layers down, and the server
#      exited on `uv_os_get_passwd` ENOENT before it listened.
#
# Nothing upstream of "start it" could have caught any of those. That is what a
# seam is, and it is why this file ends in a `curl` from the host rather than in
# an assertion about a log.
#
# ## What is real
#
# A real Incus daemon, the real published image, a real container with a real
# DHCP lease, a real trace imported by the real `ct import`, and the real
# `ct host` — reached over TCP from outside the container's namespace. The only
# stand-in is the trace, which is a committed fixture; the substrate supplies a
# real one by mounting a project.
#
# Usage:  bash ci/test/host-image-serves-in-a-container.sh [--alias NAME] [--keep]
# Needs:  `incus` with a managed bridge, and the image already published by
#         `ci/publish-host-image.sh`. Pass `--alias` to name it.
set -uo pipefail

alias_name="${CT_HOST_IMAGE_ALIAS:-}"
keep=0
while [ $# -gt 0 ]; do
	case "$1" in
	--alias)
		alias_name="${2:-}"
		shift 2
		;;
	--keep)
		keep=1
		shift
		;;
	*)
		echo "unknown argument: $1" >&2
		exit 2
		;;
	esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 1

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	echo "  [OK] $1"
}
bad() {
	fail=$((fail + 1))
	echo "  [FAILED] $1"
}

name="ct-host-serves-$$"
work="$(mktemp -d "${TMPDIR:-/tmp}/ct-serve-XXXXXX")"
cleanup() {
	if [ "${keep}" -eq 0 ]; then
		incus delete -f "${name}" >/dev/null 2>&1
	fi
	rm -rf "${work}" 2>/dev/null
	return 0
}
trap cleanup EXIT

command -v incus >/dev/null 2>&1 || {
	echo "incus is not on PATH" >&2
	exit 1
}
if [ -z "${alias_name}" ]; then
	echo "pass --alias NAME (or set CT_HOST_IMAGE_ALIAS) naming an image published" >&2
	echo "by ci/publish-host-image.sh" >&2
	exit 2
fi

echo "Step 1: the image launches as a container"
if incus launch "${alias_name}" "${name}" >/dev/null 2>&1; then
	ok "launched ${name} from ${alias_name}"
else
	bad "the image launched (no /sbin/init is the usual cause)"
	echo "CHECKS: $((pass + fail))"
	exit 1
fi

# THE INIT'S THREE-STATE SIGNAL, waited on rather than read once. `pending` is a
# real answer and reading through it is how an earlier harness reported a
# working session as a D-S12 regression.
status=""
for _ in $(seq 1 40); do
	status="$(incus exec "${name}" -- /bin/sh -c 'cat /run/isonim-net.status 2>/dev/null || echo absent' 2>/dev/null | tr -d ' \r\n')"
	[ "${status}" = "ok" ] && break
	[ "${status}" = "no-lease" ] && break
	sleep 1
done
if [ "${status}" = "ok" ]; then
	ok "its init obtained a lease (/run/isonim-net.status = ok)"
else
	bad "its init reports '${status}' rather than ok"
fi

ip=""
for _ in $(seq 1 30); do
	ip="$(incus list "${name}" --format csv -c 4 2>/dev/null | awk '{print $1}')"
	[ -n "${ip}" ] && break
	sleep 1
done
if [ -n "${ip}" ]; then
	ok "it has an address on the bridge (${ip})"
else
	bad "it has an address on the bridge"
	echo "CHECKS: $((pass + fail))"
	exit 1
fi

echo
echo "Step 2: the binary in the image actually runs"
# The whole of defect (1) above, in one assertion. `--version` is enough: the
# failure was a `dlopen` at start-up, not anything to do with arguments.
if incus exec "${name}" -- /bin/ct --version >/dev/null 2>&1; then
	ok '`ct --version` succeeds (the wrapper carries LD_LIBRARY_PATH)'
else
	bad "\`ct --version\` succeeds — see defect (1) in this file's header"
fi
# Defect (3): an OCI runtime never asks who it is; node does.
if incus exec "${name}" -- /bin/sh -c 'test -s /etc/passwd' >/dev/null 2>&1; then
	ok "/etc/passwd exists, so node's os.userInfo() can resolve uid 0"
else
	bad "/etc/passwd exists — without it the server exits on uv_os_get_passwd"
fi

echo
echo "Step 3: a trace is imported by the image's own \`ct import\`"
(cd examples/recordings/python/flow_test && zip -qr "${work}/trace.zip" .) || {
	bad "the fixture zipped"
	echo "CHECKS: $((pass + fail))"
	exit 1
}
incus exec "${name}" -- /bin/sh -c 'mkdir -p /workspace' >/dev/null 2>&1
incus file push "${work}/trace.zip" "${name}/workspace/trace.zip" >/dev/null 2>&1
recorded="$(incus exec "${name}" -- /bin/sh -c \
	'cd /workspace && /bin/ct import /workspace/trace.zip /workspace/imported 2>&1' 2>/dev/null |
	awk '/recorded with id/ { print $NF; exit }')"
if [ -n "${recorded}" ]; then
	ok "imported as ${recorded}"
else
	bad "the trace imported"
	echo "CHECKS: $((pass + fail))"
	exit 1
fi

echo
echo 'Step 4: `ct host` auto-assigns, reports, and SERVES'
incus exec "${name}" -- /bin/sh -c \
	"cd /workspace && (/bin/ct host --bind 0.0.0.0 ${recorded} > /workspace/host.log 2>&1 &)" \
	>/dev/null 2>&1

url=""
for _ in $(seq 1 60); do
	url="$(incus exec "${name}" -- /bin/sh -c 'cat /workspace/host.log 2>/dev/null' 2>/dev/null |
		awk -F= '/^CODETRACER_HOST_URL=/ { print $2; exit }')"
	[ -n "${url}" ] && break
	sleep 1
done
if [ -n "${url}" ]; then
	ok "it printed a machine-readable URL line (${url})"
else
	bad "it printed CODETRACER_HOST_URL="
	incus exec "${name}" -- /bin/sh -c 'tail -20 /workspace/host.log' 2>/dev/null | sed 's/^/      /'
	echo "CHECKS: $((pass + fail))"
	exit 1
fi

port="${url##*:}"
if [ "${port}" != "0" ] && [ -n "${port}" ]; then
	ok "the port is a real one, not the 0 it was asked to listen on (${port})"
else
	bad "the reported port is '${port}'"
fi

# THE ASSERTION THE WHOLE FILE IS FOR. From OUTSIDE the container's network
# namespace, over the bridge, to the port the server chose for itself.
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "http://${ip}:${port}/" 2>/dev/null || true)"
if [ "${code}" = "200" ]; then
	ok "the HOST can GET / from the container (${code})"
else
	bad "the host can GET / from the container (got '${code}')"
fi

# And WD1c's descriptor endpoint, from the same outside. A 200 on `/` could be a
# static file; this is the server answering a question only it can answer.
descriptor="$(curl -sS --max-time 20 "http://${ip}:${port}/deployment.json" 2>/dev/null || true)"
if printf '%s' "${descriptor}" | grep -q '"connection"'; then
	ok "and /deployment.json answers — WD1c's endpoint, from inside a session"
else
	bad "and /deployment.json answers (got: ${descriptor})"
fi

echo
echo "CHECKS: $((pass + fail))"
echo "$((pass + fail)) check(s): ${pass} OK, ${fail} FAILED"
[ "${fail}" -eq 0 ]
