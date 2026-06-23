# NixOS module for CodeTracer developer BPF setup.
#
# Grants passwordless `sudo setcap` on CodeTracer binaries the developer
# built (in ANY checkout), so the build graph can re-apply BPF capabilities
# after each recompilation. The helper is location-independent: it allows a
# target only when its basename is a known CodeTracer entrypoint binary and it
# is owned by the invoking user, instead of being pinned to one checkout path.
#
# Linux file capabilities (xattrs) are stored per-inode and lost whenever
# the binary is overwritten. This module:
#   1. Installs a single-purpose `codetracer-setcap` script on PATH that
#      runs setcap with hardcoded capabilities on the hardcoded ct binary.
#   2. Adds a sudoers rule allowing the developer to run it passwordlessly.
#
# The tup build rule calls `sudo -n codetracer-setcap` after compilation.
#
# Usage in your NixOS configuration (e.g. ~/dotfiles):
#
#   imports = [ codetracer.nixosModules.developer-bpf ];
#
#   programs.codetracer.developer-bpf = {
#     enable = true;
#     user = "myuser";
#     repoPath = "/home/myuser/metacraft/codetracer";
#   };

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.codetracer.developer-bpf;
  capabilities = "cap_bpf,cap_perfmon,cap_dac_read_search=eip";

  # CodeTracer binaries the developer may cap. setcap is only meaningful on
  # the entrypoint binaries that perform privileged tracing.
  allowedNames = [ "ct" "db-backend-record" "replay-server" "session-manager" ];

  # Default target when no path is given: derived from repoPath when set, for
  # backward-compatible `codetracer-setcap` with no argument. The build graph
  # always passes an explicit path, so repoPath is otherwise unused.
  defaultTarget =
    if cfg.repoPath != "" then "${cfg.repoPath}/src/build-debug/bin/ct" else "";

  # Helper script that applies BPF capabilities to CodeTracer binaries.
  # Installed on PATH as `codetracer-setcap`. The sudoers rule allows running
  # it via sudo without a password.
  #
  # Location-independent + safe: rather than restricting to a single hard-coded
  # checkout, the helper accepts the target binary from ANY checkout but allows
  # it only when (a) its basename is a known CodeTracer entrypoint binary AND
  # (b) it is owned by the invoking (non-root) user. So a developer can cap the
  # binaries THEY built — in `m/dev`, `metacraft/codetracer`, a worktree, a
  # release dir, anywhere — but cannot cap arbitrary root-owned system binaries
  # (privilege-escalation guard). The capabilities and binary names are fixed.
  #
  # Usage:
  #   codetracer-setcap <path>    # cap a specific binary (preferred)
  #   codetracer-setcap           # cap repoPath's default ct, if repoPath is set
  setcapHelper = pkgs.writeShellScriptBin "codetracer-setcap" ''
    set -eu
    TARGET="''${1:-${defaultTarget}}"
    if [ -z "$TARGET" ]; then
      echo "codetracer-setcap: no target binary given (and no repoPath default)" >&2
      exit 1
    fi

    # Resolve symlinks so the checks (and setcap) act on the real inode.
    TARGET="$(${pkgs.coreutils}/bin/realpath -e "$TARGET" 2>/dev/null)" || {
      echo "codetracer-setcap: file not found: ''${1:-${defaultTarget}}" >&2
      exit 1
    }

    if [ ! -f "$TARGET" ]; then
      echo "codetracer-setcap: not a regular file: $TARGET" >&2
      exit 1
    fi

    # (a) basename whitelist — only known CodeTracer entrypoint binaries.
    BASENAME="$(${pkgs.coreutils}/bin/basename "$TARGET")"
    case " ${lib.concatStringsSep " " allowedNames} " in
      *" $BASENAME "*) ;;
      *)
        echo "codetracer-setcap: refusing: not a CodeTracer binary: $BASENAME" >&2
        exit 1
        ;;
    esac

    # (b) ownership — the file must belong to the user who invoked sudo, so a
    # developer can only cap binaries they built, never root-owned ones.
    OWNER_UID="$(${pkgs.coreutils}/bin/stat -c %u "$TARGET")"
    CALLER_UID="''${SUDO_UID:-$(${pkgs.coreutils}/bin/id -u)}"
    if [ "$OWNER_UID" != "$CALLER_UID" ]; then
      echo "codetracer-setcap: refusing: $TARGET not owned by caller (uid $CALLER_UID)" >&2
      exit 1
    fi

    exec ${pkgs.libcap}/bin/setcap '${capabilities}' "$TARGET"
  '';
in
{
  options.programs.codetracer.developer-bpf = {
    enable = lib.mkEnableOption "passwordless setcap for CodeTracer developer builds";

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Username allowed to run passwordless setcap on the ct binary.
        This is the developer who builds CodeTracer from source.
      '';
      example = "zahary";
    };

    repoPath = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Optional. Absolute path to a CodeTracer checkout, used ONLY to
        compute the default target (<repoPath>/src/build-debug/bin/ct) when
        `codetracer-setcap` is called with no argument. It no longer restricts
        which binaries can be capped — the helper accepts any checkout's
        binaries that pass the basename + ownership checks. Leave empty if you
        always pass an explicit path (the build graph does).
      '';
      example = "/home/zahary/metacraft/codetracer";
    };
  };

  config = lib.mkIf cfg.enable {
    # Put codetracer-setcap on PATH so the tup build rule can find it.
    environment.systemPackages = [ setcapHelper ];

    # Scoped sudoers rule: allows ONLY the codetracer-setcap helper. The
    # helper runs setcap with fixed capabilities and only on a known
    # CodeTracer binary owned by the invoking user — no other binary can be
    # targeted, regardless of which checkout it lives in.
    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "${setcapHelper}/bin/codetracer-setcap";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
