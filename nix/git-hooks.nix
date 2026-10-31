# Git hook setup shared with the real-installer regression test.
{
  lib,
  writeShellScript,
  preCommit,
  repro,
}:
let
  # Match git-hooks.nix's supported stage aliases and default installation.
  stages = builtins.filter (stage: stage != "manual") preCommit.settings.installStages;
  hookType =
    stage:
    if
      builtins.elem stage [
        "commit"
        "merge-commit"
        "push"
      ]
    then
      "pre-${stage}"
    else
      stage;
  installStages =
    if stages == [ ] && preCommit.settings.installStages == [ ] then
      [ "pre-commit" ]
    else
      map hookType stages;
  installationScript = writeShellScript "codetracer-install-git-hooks" ''
    set -euo pipefail
      if [ "''${1:-}" != --config-only ]; then
        ${preCommit.installationScript}
      fi
      # configPath is deliberately worktree-relative in git-hooks.nix: it also
      # names the generated symlink. Hooks shared by all worktrees must instead
      # read configFile directly. Reinstall even if the symlink was unchanged,
      # so an existing relative shim is repaired on the next shell entry.
      bash "$ROOT_PATH/ci/dev/git-hooks-path.sh" anchor
      if ${lib.boolToString preCommit.settings.install.enable}; then
        if [ "''${1:-}" = --config-only ]; then
          # The new hooks will reference configFile even if the main checkout's
          # GC root still names an older configuration. Preserve upstream's
          # addGcRoot contract in the worktree performing this migration.
          ct_config_link="$ROOT_PATH"/${lib.escapeShellArg preCommit.settings.configPath}
          if [ -e "$ct_config_link" ] && [ ! -L "$ct_config_link" ]; then
            echo "ERROR: Refusing to replace an existing config at $ct_config_link" >&2
            exit 1
          fi
          [ ! -L "$ct_config_link" ] || unlink "$ct_config_link"
          if ${lib.boolToString preCommit.settings.addGcRoot}; then
            nix-store --add-root "$ct_config_link" --indirect --realise ${preCommit.settings.configFile}
          else
            ln -s ${preCommit.settings.configFile} "$ct_config_link"
          fi
        fi
        # Honor upstream's refusal to replace an existing non-generated config.
        if [ "''${1:-}" != --config-only ] && [ "$(readlink "$ROOT_PATH"/${lib.escapeShellArg preCommit.settings.configPath})" != ${lib.escapeShellArg (toString preCommit.settings.configFile)} ]; then
          echo "ERROR: git-hooks.nix did not install its generated configuration." >&2
          exit 1
        fi
        if ${lib.boolToString preCommit.settings.addGcRoot}; then
          # Shared hooks can survive removal of the worktree that selected
          # their configuration. Keep its root in the same common Git directory
          # as those hooks, rather than relying solely on worktree-local links.
          ct_shared_config="$(git rev-parse --path-format=absolute --git-common-dir)/hooks/.codetracer-pre-commit-config"
          ct_shared_owned=1
          if [ -L "$ct_shared_config" ]; then
            ct_previous_config="$(readlink "$ct_shared_config")"
            case "$ct_previous_config" in
              ${builtins.storeDir}/*-pre-commit-config.json)
                [ "''${ct_previous_config%/*}" = ${lib.escapeShellArg builtins.storeDir} ] || ct_shared_owned=0
                ;;
              *) ct_shared_owned=0 ;;
            esac
          elif [ -e "$ct_shared_config" ]; then
            ct_shared_owned=0
          fi
          if [ "$ct_shared_owned" -ne 1 ]; then
            echo "ERROR: Refusing to replace a foreign shared config root at $ct_shared_config" >&2
            exit 1
          fi
          [ ! -L "$ct_shared_config" ] || unlink "$ct_shared_config"
          nix-store --add-root "$ct_shared_config" --indirect --realise ${preCommit.settings.configFile}
        fi
        # Native pre-commit always installs into the common hooks directory.
        # Scope this override to the installer child, preserving caller config
        # and any existing command-scope settings (including authentication).
        ct_git_config_index="''${GIT_CONFIG_COUNT:-0}"
        export "GIT_CONFIG_KEY_$ct_git_config_index=core.hooksPath"
        export "GIT_CONFIG_VALUE_$ct_git_config_index="
        export GIT_CONFIG_COUNT=$((ct_git_config_index + 1))
        ${lib.concatMapStringsSep "\n" (
          stage:
          "${lib.getExe preCommit.settings.package} install --config ${lib.escapeShellArg (toString preCommit.settings.configFile)} --hook-type ${lib.escapeShellArg stage}"
        ) installStages}
      fi
  '';
in
''
  # Install pre-commit hooks automatically -- but NOT from a linked worktree
  # that would be reinstalling on another checkout's behalf.
  #
  # git-hooks.nix's installationScript writes `core.hooksPath` with `git config
  # --local`, which IS NOT PER-WORKTREE here, and it first `pre-commit
  # uninstall`s nine hook types and blanks that key before reinstalling. Run
  # from a worktree it therefore tears down and rebuilds the hooks every OTHER
  # worktree is relying on, mid-flight. The decision and its full rationale
  # live in the script below so they can be tested directly; it prints its
  # reason on stderr either way, and never writes to the repository.
  #
  # Before it runs, copy every Reprobuild hook dispatcher aside: when another
  # hook manager (prek) has already moved one to `<hook>.legacy`, the
  # installer's own move overwrites it, and only this copy survives. See "A
  # DISPATCHER THE INSTALLER DESTROYS" in ci/dev/reclaim-hook-dispatchers.sh.
  ct_hooks_status=0
  ct_hooks_snapshot=""
  if [ -n "$ROOT_PATH" ]; then
    ct_hooks_snapshot="$(bash "$ROOT_PATH/ci/dev/reclaim-hook-dispatchers.sh" snapshot || true)"
  fi
  if [ -n "$ROOT_PATH" ] && bash "$ROOT_PATH/ci/dev/should-install-git-hooks.sh"; then
    ROOT_PATH="$ROOT_PATH" bash ${installationScript} || ct_hooks_status=$?
  elif [ -n "$ROOT_PATH" ]; then
    # A worktree skips the shared installer, but can repair an older relative
    # hooksPath without tearing down the hooks the other checkouts use.
    bash "$ROOT_PATH/ci/dev/git-hooks-path.sh" anchor || ct_hooks_status=$?
    # An old generated shim still referring to configPath needs migration,
    # even though this worktree skips the destructive upstream installer.
    # Healthy shared hooks remain untouched by this path.
    ct_hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
    ct_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
    ct_upgrade_config=0
    for ct_hook_type in ${lib.escapeShellArgs installStages}; do
      for ct_suffix in "" .repro-local; do
        ct_slot="$ct_hooks_dir/$ct_hook_type$ct_suffix"
        if grep -q '^# File generated by pre-commit:' "$ct_slot" 2>/dev/null &&
           grep -Fq -- ${
             lib.escapeShellArg ("--config=" + preCommit.settings.configPath)
           } "$ct_slot"; then
          ct_upgrade_config=1
        fi
      done
    done
    if [ "$ct_upgrade_config" -eq 1 ]; then
      if [ "$ct_hooks_dir" = "$ct_common_dir/hooks" ]; then
        ROOT_PATH="$ROOT_PATH" bash ${installationScript} --config-only || ct_hooks_status=$?
      else
        echo "ERROR: refusing to migrate native hooks outside the common hooks directory: $ct_hooks_dir" >&2
        ct_hooks_status=1
      fi
    fi
    unset ct_hooks_dir ct_common_dir ct_upgrade_config ct_hook_type ct_suffix ct_slot
  fi

  # The installer moves each Reprobuild hook dispatcher aside to
  # `<hook>.legacy` and takes its slot; put the dispatchers back, restore any
  # it destroyed from the snapshot, and chain the pre-commit shim as
  # `<hook>.repro-local` (see the script).
  if [ -n "$ROOT_PATH" ]; then
    bash "$ROOT_PATH/ci/dev/reclaim-hook-dispatchers.sh" --snapshot "$ct_hooks_snapshot" || true
  fi
  unset ct_hooks_snapshot

  # The installer above ends by writing the RELATIVE `core.hooksPath=.git/hooks`
  # into the config every worktree shares; in a linked worktree that path names
  # nothing, so git silently runs no hooks there. `anchor` repairs that value
  # and runs on every entry, from any checkout, so a value an earlier entry
  # left behind is healed too. `check` then reports, loudly, any relative
  # value `anchor` could not attribute; setup then fails rather than claiming
  # that the shared checks are installed.
  if [ -n "$ROOT_PATH" ]; then
    bash "$ROOT_PATH/ci/dev/git-hooks-path.sh" check || ct_hooks_status=$?
  fi

  # Reclamation preserves an existing dispatcher; it cannot create one in a
  # fresh clone. Bootstrap with the same pinned Repro that will service it.
  if [ -n "$ROOT_PATH" ]; then
    ${repro}/bin/repro hooks ensure --vcs "$ROOT_PATH" || {
      echo "ERROR: CodeTracer could not install the Repro publication gate." >&2
      return 1 2>/dev/null || exit 1
    }
  fi
  if [ "$ct_hooks_status" -ne 0 ]; then
    echo "ERROR: CodeTracer could not install its configured Git checks." >&2
    return 1 2>/dev/null || exit 1
  fi
  unset ct_hooks_status
''
