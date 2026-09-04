#!/usr/bin/env bash
# NOT-A-CI-GATE: one-time developer machine setup.
#
# Run as `just developer-setup`; it grants a workstation the BPF
# capabilities bpftrace needs. It asserts nothing and has no verdict.
# scripts/developer-setup.sh — One-time developer machine setup for CodeTracer
#
# Usage:
#   just developer-setup [--without-bpf | --bpf=false]
#
# === Design Overview ===
#
# CodeTracer uses BPF (Berkeley Packet Filter) via bpftrace for live process
# tree monitoring during CI runs. BPF programs require elevated privileges:
# specifically CAP_BPF, CAP_PERFMON, and CAP_DAC_READ_SEARCH capabilities
# (Linux kernel >= 5.8, see https://lwn.net/Articles/820560/).
#
# For END USERS, `ct install` (with all features enabled by default) sets
# cap_bpf,cap_perfmon,cap_dac_read_search on the ct binary itself for the
# native libbpf backend, installs monitor.bpf.o to /usr/local/lib/codetracer/,
# and optionally copies bpftrace as a fallback. Users can pass --no-bpf to
# skip BPF setup entirely.
# On NixOS, the equivalent is achieved via security.wrappers in the NixOS
# module (see nix/packages/codetracer-appimage/nixos-module.nix).
#
# For DEVELOPERS, we need more flexibility. During development, you iterate
# on BPF scripts — writing new tracepoint handlers, modifying output formats,
# testing different kernel probes — and need to run arbitrary bpftrace
# invocations without sudo each time. This script provides that by:
#
# 1. Running the standard end-user BPF setup (Phase 2a: `ct install --bpf`),
#    which creates /usr/local/lib/codetracer/bpftrace for production use.
#
# 2. Additionally copying the dev shell's bpftrace to a separate path
#    /usr/local/lib/codetracer/bpftrace-dev with the same capabilities
#    (Phase 2b). This binary is NOT used by the CodeTracer runtime — it
#    exists purely for developer convenience.
#
# Why a separate binary instead of granting the developer ambient capabilities?
#   - Linux file capabilities (setcap) are per-inode, not per-user. There is
#     no way to say "user X can use CAP_BPF from any binary."
#   - Ambient capabilities (prctl PR_CAP_AMBIENT) require the parent process
#     to already hold the capability, which defeats the purpose.
#   - The group + setcap approach is the established best practice: the binary
#     is owned by root:codetracer-bpf (750), so only group members can execute
#     it, and the capabilities are inherited on exec.
#
# Why copy instead of setcap on the Nix store binary?
#   - The Nix store (/nix/store/...) is read-only. setcap modifies file
#     extended attributes, which would fail. Copying to a mutable path is
#     the only option.
#
# Why /usr/local/lib/codetracer/ instead of a user-local path?
#   - setcap requires root (only root can grant capabilities). So we need
#     sudo for the initial setup regardless.
#   - File capabilities are cleared on write (kernel security measure), so a
#     user-writable path would lose capabilities on the next copy/update.
#   - /usr/local/lib/ is the FHS-standard location for locally-installed
#     architecture-dependent files.
#
# On NixOS, all of this is unnecessary — the security.wrappers mechanism
# handles capability granting declaratively, and developers should add
# bpftrace to their NixOS config with the codetracer module enabled.

set -euo pipefail

CT_BIN="src/build-debug/bin/ct"
if [ ! -f "$CT_BIN" ]; then
	echo "ct binary not found at $CT_BIN"
	echo "Please run 'just build-once' first."
	exit 1
fi

echo "=== CodeTracer Developer Machine Setup ==="
echo

# Phase 1: Non-privileged setup (PATH, desktop file)
echo "--- Phase 1: PATH and desktop file setup ---"
"$CT_BIN" install --bpf=false
echo

# Phase 2: BPF developer setup (requires sudo unless NixOS-managed)
SKIP_BPF=false
for flag in "$@"; do
	case "$flag" in
	--without-bpf | --bpf=false) SKIP_BPF=true ;;
	esac
done

if [ "$(uname)" != "Linux" ]; then
	echo "--- BPF setup skipped (not Linux) ---"
	exit 0
fi

if [ "$SKIP_BPF" = "true" ]; then
	echo "--- BPF setup skipped (--without-bpf) ---"
	exit 0
fi

# Check if NixOS manages bpftrace via security.wrappers
if [ -f /run/wrappers/bin/codetracer-bpftrace ]; then
	echo "--- BPF support is managed by NixOS (security.wrappers) ---"
	echo "  Wrapper: /run/wrappers/bin/codetracer-bpftrace"
	echo "  Make sure your user is in the 'codetracer-bpf' group:"
	echo "    users.users.$(whoami).extraGroups = [ \"codetracer-bpf\" ];"
	exit 0
fi

echo "--- Phase 2: BPF developer setup ---"
echo
echo "This grants your user the ability to run bpftrace without sudo,"
echo "so you can iterate on BPF scripts during development."
echo

# Check if bpftrace is available
BPFTRACE_PATH="$(command -v bpftrace 2>/dev/null || true)"
if [ -z "$BPFTRACE_PATH" ]; then
	echo "bpftrace is not installed."
	if command -v apt &>/dev/null; then
		echo "  Install with: sudo apt install bpftrace"
	elif command -v dnf &>/dev/null; then
		echo "  Install with: sudo dnf install bpftrace"
	elif command -v pacman &>/dev/null; then
		echo "  Install with: sudo pacman -S bpftrace"
	elif command -v nix-env &>/dev/null; then
		echo "  Install with: nix-env -iA nixpkgs.bpftrace"
		echo "  Or add bpftrace to your NixOS configuration."
	else
		echo "  Install bpftrace using your package manager."
	fi
	echo
	echo "After installing bpftrace, re-run: just developer-setup"
	exit 1
fi

# Resolve the real path (follow symlinks, e.g. Nix store paths)
BPFTRACE_REAL="$(readlink -f "$BPFTRACE_PATH")"

echo "This will:"
echo "  1. Set up the standard CodeTracer BPF runtime (group + capabilities)"
echo "  2. Grant your dev shell's bpftrace ($BPFTRACE_REAL) BPF capabilities"
echo "     so you can run arbitrary bpftrace scripts without sudo"
echo
echo "Sudo is required (one-time setup)."
echo

# Validate username before interpolating into sudo script
CURRENT_USER="$(whoami)"
if ! grep -qE '^[a-zA-Z_][a-zA-Z0-9_.-]*$' <<<"$CURRENT_USER"; then
	echo "Error: unexpected characters in username: $CURRENT_USER"
	exit 1
fi

# Phase 2a: Standard BPF setup via ct install (same as end-user setup)
"$CT_BIN" install --path=false --desktop=false --bpf

# Phase 2b: Developer-specific — capabilities-aware copy of the dev shell's
# bpftrace. This is separate from the production binary so developers can
# run arbitrary scripts (not just the ones bundled with CodeTracer).
echo
echo "--- Granting BPF capabilities to dev shell bpftrace ---"

DEV_BPFTRACE="/usr/local/lib/codetracer/bpftrace-dev"

sudo bash -c "
  set -e
  cp '$BPFTRACE_REAL' '$DEV_BPFTRACE'
  chown root:codetracer-bpf '$DEV_BPFTRACE'
  chmod 750 '$DEV_BPFTRACE'
  setcap 'cap_bpf,cap_perfmon,cap_dac_read_search+ep' '$DEV_BPFTRACE'
"

echo "  Installed: $DEV_BPFTRACE"
echo "  Capabilities: cap_bpf,cap_perfmon,cap_dac_read_search+ep"
echo

# Create a convenience wrapper in the repo's build dir so developers
# can just run ./src/build-debug/bin/bpftrace-dev <script>.
# This path is in .gitignore (matched by **/bin/).
WRAPPER="src/build-debug/bin/bpftrace-dev"
mkdir -p "$(dirname "$WRAPPER")"
cat >"$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Convenience wrapper for the capabilities-enabled bpftrace binary.
# Created by `just developer-setup`. Not checked into git.
exec /usr/local/lib/codetracer/bpftrace-dev "$@"
WRAPPER_EOF
chmod +x "$WRAPPER"

# Phase 2c: Passwordless setcap sudoers rule for native BPF backend
#
# The native BPF backend (libbpf-based, replaces bpftrace) requires
# cap_bpf+cap_perfmon+cap_dac_read_search on the ct binary itself.
# Since setcap modifies filesystem extended attributes (xattrs), it requires
# root. And since capabilities are stored per-inode, they are lost every time
# the binary is recompiled.
#
# To avoid requiring `sudo` on every build, we install a sudoers drop-in
# rule that allows the developer to run setcap WITHOUT a password, but ONLY
# on the specific binary paths that need it. This is least-privilege:
# the user cannot grant capabilities to arbitrary binaries.
echo
echo "--- Phase 2c: Passwordless setcap for native BPF backend ---"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CT_ABS_PATH="$REPO_ROOT/src/build-debug/bin/ct"
SETCAP_BIN="$(command -v setcap)"

# The native BPF backend (libbpf-based, replaces bpftrace) requires
# cap_bpf+cap_perfmon+cap_dac_read_search on the ct binary itself.
# Since setcap modifies filesystem extended attributes (xattrs), it requires
# root. And since capabilities are stored per-inode, they are lost every time
# the binary is recompiled.
#
# The tup build rule (`!codetracer_bpf` in Tuprules.tup) runs
# `sudo -n setcap ... %o` after each compilation. For this to work without
# a password prompt, we need a sudoers rule allowing the developer to run
# setcap on the specific ct binary path.
#
# On NixOS, /etc/sudoers is generated declaratively — there is no
# /etc/sudoers.d/ directory. The user must add the rule to their NixOS
# configuration instead.

if [ -f /etc/NIXOS ]; then
	# --- NixOS: sudoers is managed declaratively via the NixOS module ---
	echo "  NixOS detected — sudoers is managed declaratively."
	echo
	echo "  Import the developer-bpf module in your NixOS configuration"
	echo "  (e.g. ~/dotfiles):"
	echo
	echo "    imports = [ codetracer.nixosModules.developer-bpf ];"
	echo
	echo "    programs.codetracer.developer-bpf = {"
	echo "      enable = true;"
	echo "      user = \"$CURRENT_USER\";"
	echo "      repoPath = \"$REPO_ROOT\";"
	echo "    };"
	echo
	echo "  Then run: sudo nixos-rebuild switch"
	echo
	echo "  Module source: $REPO_ROOT/nix/modules/developer-bpf.nix"
	echo

	# Check if the sudoers rule is already active (NixOS rebuild done).
	if command -v codetracer-setcap &>/dev/null && sudo -n codetracer-setcap 2>/dev/null; then
		echo "  Passwordless setcap is active — BPF capabilities set on $CT_ABS_PATH"
	elif [ -f "$CT_ABS_PATH" ]; then
		echo "  Passwordless setcap not yet active. Applying manually (requires sudo)..."
		sudo "$SETCAP_BIN" 'cap_bpf,cap_perfmon,cap_dac_read_search=eip' "$CT_ABS_PATH"
		echo "  Done. After importing the NixOS module above, future builds will be automatic."
	fi
else
	# --- Non-NixOS: install sudoers drop-in file ---
	SUDOERS_FILE="/etc/sudoers.d/codetracer-setcap-${CURRENT_USER}"

	SUDOERS_CONTENT="# Allow $CURRENT_USER to grant BPF capabilities to the CodeTracer ct binary
# without a password. Installed by: just developer-setup
# Repo: $REPO_ROOT
#
# Only the exact setcap invocation below is permitted — no wildcards.
# The tup build rule chains 'sudo -n setcap ...' after each compilation.
Cmnd_Alias CODETRACER_SETCAP = \\
  $SETCAP_BIN cap_bpf\\,cap_perfmon\\,cap_dac_read_search=eip $CT_ABS_PATH

$CURRENT_USER ALL=(root) NOPASSWD: CODETRACER_SETCAP
"

	echo "  Installing sudoers rule: $SUDOERS_FILE"
	echo "  Allows: sudo setcap 'cap_bpf,...=eip' $CT_ABS_PATH"
	echo

	# Write via a temp file + visudo -cf to validate syntax before installing.
	# A malformed sudoers file can lock out sudo entirely.
	SUDOERS_TMP="$(mktemp)"
	echo "$SUDOERS_CONTENT" >"$SUDOERS_TMP"

	sudo bash -c "
    set -e
    # Validate syntax — visudo -cf exits non-zero on parse errors.
    visudo -cf '$SUDOERS_TMP'
    # Ensure the drop-in directory exists.
    mkdir -p /etc/sudoers.d
    # Install with correct ownership and permissions (0440, root:root).
    install -o root -g root -m 0440 '$SUDOERS_TMP' '$SUDOERS_FILE'
  "
	rm -f "$SUDOERS_TMP"

	echo "  Sudoers rule installed."
	echo

	# Apply setcap to the ct binary right now if it exists.
	if [ -f "$CT_ABS_PATH" ]; then
		echo "  Granting BPF capabilities to $CT_ABS_PATH ..."
		sudo "$SETCAP_BIN" 'cap_bpf,cap_perfmon,cap_dac_read_search=eip' "$CT_ABS_PATH"
		echo "  Done."
	else
		echo "  ct binary not found at $CT_ABS_PATH — capabilities will be set on next build."
	fi
fi

echo
echo "=== Developer setup complete ==="
echo
echo "You can now run BPF scripts without sudo:"
echo "  $WRAPPER your-script.bt"
echo "  /usr/local/lib/codetracer/bpftrace-dev your-script.bt"
echo
echo "Native BPF backend: tup automatically re-applies BPF capabilities"
echo "to $CT_ABS_PATH after each recompilation (requires the sudoers rule above)."
echo
echo "Note: Log out and back in for codetracer-bpf group membership to take effect."
echo "  (Or run 'newgrp codetracer-bpf' to activate it in the current shell.)"
