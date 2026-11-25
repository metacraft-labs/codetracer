#!/usr/bin/env bash
# ci/test/gpui-host-provisioning-test.sh — a GPUI shard gives a bare host
# (an ephemeral garm VM) what the GPUI window and its compositor need, before
# anything uses them, and leaves a host that has them alone.
#
# Each was a failed run on garm (run 43996043232 and the one before):
#   - a Vulkan driver (lavapipe): "Failed to create surface for any enabled
#     backend";
#   - a cursor theme (Adwaita): "no cursor theme on this machine";
#   - a D-Bus session configuration: dbus-run-session could not open
#     /etc/dbus-1/session.conf, so sway never started;
#   - an EGL vendor (Mesa's): GNOME Shell "Unable to initialize the Clutter
#     backend: no available drivers found" (run 45292632494).
# For each, the step must exist, take it from this flake's nixpkgs, keep the
# host's own when there is one, and come before the first step that runs the
# window (the build of the windowed front-end).
set -euo pipefail
cd "$(dirname "$0")/../.."
wf=.github/workflows/gpui-window-captures.yml
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

line_of() { grep -nF -- "$1" "${wf}" | head -n 1 | cut -d: -f1; }
first_use="$(line_of '- name: Build the windowed GPUI front-end the scenario lane opens')"
[ -n "${first_use}" ] || fail "no 'Build the windowed GPUI front-end' step to order against"

check() { # name, nixpkgs attribute, host-has test
	local name="$1" attr="$2" probe="$3" at body
	at="$(line_of "- name: ${name}")"
	if [ -z "${at}" ]; then
		fail "no step '${name}'"
		return
	fi
	body="$(sed -n "${at},\$p" "${wf}" | sed -n '2,/^      - name:/p')"
	grep -qF "nixpkgs#${attr}" <<<"${body}" || fail "'${name}' does not take ${attr} from this flake's nixpkgs"
	grep -qF -- "${probe}" <<<"${body}" || fail "'${name}' does not keep a host's own (${probe})"
	if [ -n "${first_use}" ] && [ "${at}" -ge "${first_use}" ]; then
		fail "'${name}' runs after the windowed front-end's build"
	else
		ok "'${name}': nixpkgs#${attr}, only where the host lacks it, before the window runs"
	fi
}
check "Give Vulkan a software driver where the host has none" mesa "/run/opengl-driver/share/vulkan/icd.d"
# GNOME Shell (PLAT-69's second compositor) needs an EGL vendor, which a
# bare garm VM lacks too ("no available drivers found", run 45292632494).
check "Give Vulkan a software driver where the host has none" mesa "/run/opengl-driver/share/glvnd/egl_vendor.d"
check "Give the window a cursor theme where the host has none" adwaita-icon-theme "/run/current-system/sw/share/icons/Adwaita/cursors"
check "Give dbus-run-session a session bus configuration where the host has none" dbus.out "/etc/dbus-1/session.conf"

# nixpkgs' session.conf includes /etc/dbus-1/session.conf for local
# overrides, so linking it there makes it include itself and the bus refuses
# to start (run 44940608244, shard 1). The step must write a copy without that
# include, and check the bus starts on it.
dbus_at="$(line_of "- name: Give dbus-run-session a session bus configuration where the host has none")"
# shellcheck disable=SC2016 # the step's own text, not an expansion
if [ -n "${dbus_at}" ]; then
	dbus_body="$(sed -n "${dbus_at},\$p" "${wf}" | sed -n '2,/^      - name:/p' | grep -v '^ *#')"
	if grep -qE 'ln -s[^|]*session\.conf' <<<"${dbus_body}"; then
		fail "the D-Bus step links nixpkgs' session.conf into /etc, which then includes itself"
	elif ! grep -qF 'grep -vF "${self}"' <<<"${dbus_body}" ||
		! grep -qF "self='<include ignore_missing=\"yes\">/etc/dbus-1/session.conf</include>'" <<<"${dbus_body}"; then
		fail "the D-Bus step does not drop the include of /etc/dbus-1/session.conf from its copy"
	elif ! grep -qF -- '--config-file=/etc/dbus-1/session.conf' <<<"${dbus_body}"; then
		fail "the D-Bus step does not check that a bus starts on the configuration it wrote"
	else
		ok "the D-Bus configuration is a copy without its self-include, and a bus starts on it"
	fi
fi

if [ "${failures}" -gt 0 ]; then
	echo "gpui-host-provisioning: ${failures} failure(s)"
	exit 1
fi
echo "gpui-host-provisioning: ok"
