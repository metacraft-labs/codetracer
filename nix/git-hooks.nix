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
        # pre-commit does not keep the absolute path it was given: its
        # `_adjust_args_and_chdir` (pre_commit/main.py) changes to the
        # repository top level and then applies `os.path.relpath` to
        # `--config`, and `install` writes that relative path into the shim.
        # The shim would then name the store path relative to THIS checkout
        # (`../../../../nix/store/…`) and resolve only from worktrees at the
        # same depth; git runs shared hooks from each worktree's own top
        # level. Pin every shim just written back to the absolute configFile,
        # and fail rather than leave a shim that names anything else.
        ct_native_hooks="$(git rev-parse --path-format=absolute --git-common-dir)/hooks"
        for ct_hook_type in ${lib.escapeShellArgs installStages}; do
          ct_shim="$ct_native_hooks/$ct_hook_type"
          ct_pinned_args="ARGS=(hook-impl --config=${toString preCommit.settings.configFile} --hook-type=$ct_hook_type)"
          # Exactly one ARGS line of exactly the form `install` writes for
          # these options; anything else is a template this does not know.
          if ! grep -q '^# File generated by pre-commit:' "$ct_shim" 2>/dev/null ||
             [ "$(grep -c '^ARGS=' "$ct_shim")" -ne 1 ] ||
             ! grep -Eqx "ARGS=\(hook-impl --config=[^ ]+ --hook-type=$ct_hook_type\)" "$ct_shim"; then
            echo "ERROR: pre-commit did not write the expected $ct_hook_type shim at $ct_shim" >&2
            exit 1
          fi
          ct_shim_text="$(while IFS= read -r ct_line || [ -n "$ct_line" ]; do
            case "$ct_line" in
              'ARGS=(hook-impl --config='*) printf '%s\n' "$ct_pinned_args" ;;
              *) printf '%s\n' "$ct_line" ;;
            esac
          done <"$ct_shim")"
          # Rewrite in place so the shim keeps its inode and executable mode.
          printf '%s\n' "$ct_shim_text" >"$ct_shim"
          grep -qxF -- "$ct_pinned_args" "$ct_shim" || {
            echo "ERROR: could not pin the $ct_hook_type shim at $ct_shim to its absolute configuration" >&2
            exit 1
          }
        done
        unset ct_native_hooks ct_hook_type ct_shim ct_pinned_args ct_shim_text ct_line
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
    # A generated shim whose `--config=` is not absolute needs migration, even
    # though this worktree skips the destructive upstream installer. Older
    # shims name the worktree-local configPath; shims installed before the
    # pinning step above name the store path relative to the checkout that
    # installed them, which resolves only from worktrees at that depth.
    # Healthy shared hooks (absolute configFile) remain untouched by this path.
    ct_hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
    ct_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
    ct_upgrade_config=0
    ct_unresolvable_config=0
    for ct_hook_type in ${lib.escapeShellArgs installStages}; do
      for ct_suffix in "" .repro-local; do
        ct_slot="$ct_hooks_dir/$ct_hook_type$ct_suffix"
        if grep -q '^# File generated by pre-commit:' "$ct_slot" 2>/dev/null &&
           grep -Eq -- '^ARGS=\(hook-impl --config=[^/]' "$ct_slot"; then
          ct_upgrade_config=1
          grep -Fq -- ${
            lib.escapeShellArg ("--config=" + preCommit.settings.configPath + " ")
          } "$ct_slot" || ct_unresolvable_config=1
        fi
      done
    done
    if [ "$ct_upgrade_config" -eq 1 ]; then
      if [ "$ct_hooks_dir" = "$ct_common_dir/hooks" ]; then
        ROOT_PATH="$ROOT_PATH" bash ${installationScript} --config-only || ct_hooks_status=$?
      elif [ "$ct_unresolvable_config" -eq 0 ]; then
        # The hooks directory is not at $ct_common_dir/hooks — this happens
        # with the `repo` tool, which puts hooks under project-objects/ while
        # --git-common-dir points to projects/. The old .pre-commit-config.yaml
        # symlink still resolves correctly, so this is cosmetic, not a
        # correctness issue. Warn but do not fail the build.
        echo "WARNING: cannot migrate native hooks to absolute config path outside the common hooks directory: $ct_hooks_dir" >&2
        echo "  (hooks continue to work via the .pre-commit-config.yaml symlink)" >&2
      else
        # A checkout-relative store path has no symlink to fall back on.
        echo "ERROR: native hooks in $ct_hooks_dir name their configuration relative to another checkout, and cannot be migrated outside the common hooks directory" >&2
        ct_hooks_status=1
      fi
    fi
    unset ct_hooks_dir ct_common_dir ct_upgrade_config ct_unresolvable_config ct_hook_type ct_suffix ct_slot
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
  #
  # On a CI runner (GITHUB_ACTIONS=true) that build IS the one the checkout
  # should run, so a hook a different build wrote is re-anchored to it. The
  # persistent runners keep their checkout's .git/hooks between jobs, and
  # after the pin moved from repro 0.2.24 to 0.2.25 a plain `ensure` refused
  # the hooks 0.2.24 had written ("refused-foreign-contract") and failed every
  # job on gpu-server-002 in sibling provisioning (run 44081496736: GPUI 1,
  # TUI 2, 4 and 8). On a workstation a foreign hook still means a different
  # `repro` supplies the shell, which the operator reconciles, so it fails
  # there as before.
  ct_repro_anchor=()
  if [ "''${GITHUB_ACTIONS:-}" = true ]; then
    ct_repro_anchor=(--re-anchor)
  fi
  # ONLY THE MAIN CHECKOUT WRITES THE SHARED HOOKS. A linked worktree shares
  # its main checkout's hooks directory, and a worktree whose flake pins a
  # different Repro build rewrote them on shell entry -- for the main checkout
  # and every other worktree, whose shells then refused with "could not install
  # the Repro publication gate" (11-18, worktrees on reprobuild 0.2.24 and
  # a765c3e79d4). From a linked worktree the step is check-only: each managed
  # hook's contract token is put to this build with `repro hooks protocol`
  # (the handshake the hooks themselves make), a mismatch is reported with the
  # remedy, and nothing is written. CT_REPRO_HOOKS_WRITE=1 opts a worktree back
  # in. ci/test/repro-hooks-worktree-check-test.sh holds both.
  ct_repro_git_dir=""
  ct_repro_common_dir=""
  if [ -n "$ROOT_PATH" ]; then
    ct_repro_git_dir="$(git -C "$ROOT_PATH" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    ct_repro_common_dir="$(git -C "$ROOT_PATH" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  fi
  if [ -n "$ROOT_PATH" ] && [ -n "$ct_repro_git_dir" ] && [ "$ct_repro_git_dir" != "$ct_repro_common_dir" ] &&
    [ "''${CT_REPRO_HOOKS_WRITE:-}" != 1 ]; then
    ct_repro_hooks_dir="$(git -C "$ROOT_PATH" rev-parse --path-format=absolute --git-path hooks)"
    ct_repro_foreign=()
    ct_repro_seen=0
    for ct_repro_hook in "$ct_repro_hooks_dir"/*.repro-managed; do
      [ -f "$ct_repro_hook" ] || continue
      ct_repro_seen=1
      ct_repro_token="$(grep -o 'reprobuild\.managed-hook\.v1\.[a-z-]*\.[0-9a-f]*' "$ct_repro_hook" | head -n 1)"
      if [ -z "$ct_repro_token" ] ||
        ! ${repro}/bin/repro hooks protocol --require=2 --hook-contract="$ct_repro_token" >/dev/null 2>&1; then
        ct_repro_foreign+=("''${ct_repro_hook##*/}")
      fi
    done
    if [ "$ct_repro_seen" = 0 ]; then
      echo "repro hooks: the shared hooks in $ct_repro_hooks_dir are not installed; this linked worktree does not write them. Enter the dev shell from the main checkout ($(dirname "$ct_repro_common_dir")), or set CT_REPRO_HOOKS_WRITE=1 here." >&2
    elif [ "''${#ct_repro_foreign[@]}" -gt 0 ]; then
      echo "repro hooks: ''${ct_repro_foreign[*]} in $ct_repro_hooks_dir were written by a different Repro build than this shell's (${repro}); this linked worktree leaves them as they are. The main checkout's shell, or CT_REPRO_HOOKS_WRITE=1 here, re-anchors them -- only once the build every checkout should run is agreed." >&2
    fi
    unset ct_repro_hooks_dir ct_repro_foreign ct_repro_seen ct_repro_hook ct_repro_token
  elif [ -n "$ROOT_PATH" ]; then
    ${repro}/bin/repro hooks ensure --vcs "''${ct_repro_anchor[@]}" "$ROOT_PATH" || {
      echo "ERROR: CodeTracer could not install the Repro publication gate." >&2
      return 1 2>/dev/null || exit 1
    }
  fi
  unset ct_repro_anchor ct_repro_git_dir ct_repro_common_dir
  if [ "$ct_hooks_status" -ne 0 ]; then
    echo "ERROR: CodeTracer could not install its configured Git checks." >&2
    return 1 2>/dev/null || exit 1
  fi
  unset ct_hooks_status
''
