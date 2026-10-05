#!/bin/sh
# Extract an AppImage's embedded squashfs tree WITHOUT running the AppImage.
#
#   appimage-extract.sh <CodeTracer.AppImage> <dest-dir>
#
# `<appimage> --appimage-extract` executes the AppImage's runtime, which is a
# dynamically linked ELF for /lib64/ld-linux-x86-64.so.2. That path does not
# exist on the NixOS release runners, so the runtime cannot start there. The
# squashfs image simply follows the runtime's ELF image in the file, so its
# offset is the end of the ELF section header table:
#
#   e_shoff + e_shentsize * e_shnum     (ELF64 header offsets 40, 58, 60)
#
# and `unsquashfs -o <offset>` reads it in place. Needs od and unsquashfs.
set -eu

die() {
	printf 'appimage-extract: ERROR: %s\n' "$*" >&2
	exit 1
}

[ $# -eq 2 ] || die 'usage: appimage-extract.sh <appimage> <dest-dir>'
img="$1"
dest="$2"
[ -f "$img" ] || die "$img does not exist"
command -v unsquashfs >/dev/null 2>&1 || die 'unsquashfs not found (squashfs-tools)'
[ ! -e "$dest" ] || die "$dest already exists; refusing to extract over it"

# Only ELF64 little-endian (x86_64, aarch64) AppImages are handled.
magic="$(od -An -c -N 4 "$img" | tr -d ' ')"
[ "$magic" = '177ELF' ] || die "$img is not an ELF file (magic '$magic')"
class="$(od -An -t u1 -j 4 -N 1 "$img" | tr -d ' ')"
[ "$class" = 2 ] || die "$img is not ELF64"

shoff="$(od -An -t u8 -j 40 -N 8 "$img" | tr -d ' ')"
shentsize="$(od -An -t u2 -j 58 -N 2 "$img" | tr -d ' ')"
shnum="$(od -An -t u2 -j 60 -N 2 "$img" | tr -d ' ')"
offset=$((shoff + shentsize * shnum))

sqmagic="$(od -An -c -j "$offset" -N 4 "$img" | tr -d ' ')"
[ "$sqmagic" = 'hsqs' ] || die "no squashfs image at offset $offset of $img (found '$sqmagic')"

mkdir -p "$(dirname "$dest")"
unsquashfs -q -n -o "$offset" -d "$dest" "$img" >/dev/null ||
	die "unsquashfs failed on $img at offset $offset"
[ -x "$dest/AppRun" ] || die "$img extracted, but has no executable AppRun at its root"
