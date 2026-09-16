#!/usr/bin/env bash
# Assemble get/dist/ — the static tree published to https://get.codetracer.com.
#
# The install scripts are SINGLE-SOURCED from the repo's canonical installers:
#   /sh   <- install-on-distributions.sh   (the POSIX installer)
#   /pwsh <- install.ps1 if present, else get/pwsh.stub.ps1 (coming-soon stub)
# so get.codetracer.com always re-serves the repo's real installer as text/plain
# (Content-Type forced by get/_headers). See
# metacraft-dev-guidelines/policies/product-install-domains.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
out="$here/dist"

rm -rf "$out"
mkdir -p "$out"

cp "$here/index.html" "$out/index.html"
cp "$here/_headers" "$out/_headers"

rev="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# /sh — keep the shebang on line 1, then inject a visible provenance/version
# header (policy §2.5), then the rest of the canonical installer verbatim.
sh_src="$repo_root/install-on-distributions.sh"
{
  head -n 1 "$sh_src"
  printf '#\n'
  printf '# CodeTracer installer — served from https://get.codetracer.com/sh\n'
  printf '# Source: metacraft-labs/codetracer install-on-distributions.sh @ %s (assembled %s)\n' "$rev" "$now"
  printf '# Inspect before running:  curl -fsSL https://get.codetracer.com/sh | less\n'
  printf '# Artifacts come from the release store (GitHub Releases / downloads.codetracer.com).\n'
  printf '#\n'
  tail -n +2 "$sh_src"
} > "$out/sh"

# /pwsh — the repo's PowerShell installer if it exists, else the coming-soon stub.
if [ -f "$repo_root/install.ps1" ]; then
  {
    printf '# CodeTracer installer — served from https://get.codetracer.com/pwsh\n'
    printf '# Source: metacraft-labs/codetracer install.ps1 @ %s (assembled %s)\n#\n' "$rev" "$now"
    cat "$repo_root/install.ps1"
  } > "$out/pwsh"
else
  cp "$here/pwsh.stub.ps1" "$out/pwsh"
fi

echo "Assembled $out:"
ls -la "$out"
