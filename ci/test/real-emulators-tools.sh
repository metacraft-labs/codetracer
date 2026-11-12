#!/usr/bin/env bash
# real-emulators-tools.sh [OUT] — the real terminal emulators and display tools
# the `tui-real-emulators` lane drives (CodeTracer-TUI-Terminal-Adaptation.md
# §13.4), each from THIS checkout's pinned nixpkgs (`--inputs-from .`), so a
# measurement names a build and the lane reruns against the same one.
#
# Writes, under OUT (default build/real-emulators/tools):
#   bin/          one symlink per program the suite runs;
#   versions.txt  `<package> <store path>` for every package provided;
#   missing.txt   `<package>: <reason>` for every package that could not be
#                 provided (a failed build, an unsupported platform). The
#                 suite turns each line into a MISSING-PREREQ skip of the
#                 emulators that need it; nothing here fails the lane.
#   fonts.conf    a fontconfig configuration naming ONE font directory
#                 (DejaVu), so every emulator draws the same font and a
#                 persona's cell size is a property of the terminal, not of
#                 whatever fonts the host has.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${1:-${root}/build/real-emulators/tools}"
rm -rf "${out}"
mkdir -p "${out}/bin"
: >"${out}/versions.txt"
: >"${out}/missing.txt"

# package -> the programs of it the suite runs. Order is the build order.
packages=(
	"xterm:xterm"
	"kitty:kitty"
	"ghostty:ghostty"
	"alacritty:alacritty"
	"foot:foot"
	"tmux:tmux"
	"xorg.xvfb:Xvfb"
	"imagemagick:magick"
	"xclip:xclip"
	"xdotool:xdotool"
	"wl-clipboard:wl-paste wl-copy"
	"util-linux:script"
	"dejavu_fonts:"
)
for entry in "${packages[@]}"; do
	pkg="${entry%%:*}"
	progs="${entry#*:}"
	# The outputs a user would install (`util-linux`'s programs are in its
	# `bin` output, which is one of them).
	if ! paths="$(cd "${root}" && nix build --no-link --print-out-paths \
		--inputs-from . "nixpkgs#${pkg}" 2>"${out}/${pkg}.log")" ||
		[ -z "${paths}" ]; then
		echo "${pkg}: nix build nixpkgs#${pkg} failed ($(tail -1 "${out}/${pkg}.log"))" >>"${out}/missing.txt"
		continue
	fi
	path="$(printf '%s\n' "${paths}" | head -1)"
	for prog in ${progs}; do
		found=""
		for p in ${paths}; do
			[ -x "${p}/bin/${prog}" ] && found="${p}/bin/${prog}" && break
		done
		if [ -n "${found}" ]; then
			ln -sf "${found}" "${out}/bin/${prog}"
			path="${found%/bin/*}"
		else
			echo "${pkg}: no bin/${prog} in ${path}" >>"${out}/missing.txt"
		fi
	done
	echo "${pkg} ${path}" >>"${out}/versions.txt"
	if [ "${pkg}" = "dejavu_fonts" ]; then
		cat >"${out}/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>${path}/share/fonts</dir>
  <cachedir>${out}/fontcache</cachedir>
</fontconfig>
EOF
	fi
done
echo "real-emulators-tools: $(wc -l <"${out}/versions.txt") packages in ${out}, $(wc -l <"${out}/missing.txt") missing"
