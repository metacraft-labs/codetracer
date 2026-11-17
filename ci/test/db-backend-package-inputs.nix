# db-backend's package source holds everything its build reads.
#
# nix/packages/default.nix builds db-backend from an explicit file set (not the
# whole checkout, so a commit elsewhere leaves its derivation and cached output
# alone). A path dependency added to a manifest but not to that set would break
# only the Nix build, so this lays the source out as the build's postUnpack does
# -- the package source, with codetracer-trace-format beside it from its flake
# input -- and follows every path dependency from src/db-backend's manifest,
# transitively, read from the manifests rather than listed here.
# Run by ci/lint/nix.sh.
{
  repo ? ../..,
}:
let
  flake = builtins.getFlake "git+file://${toString repo}?submodules=1";
  packages = flake.packages.${builtins.currentSystem};
  db = packages.db-backend;
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
in
pkgs.runCommand "db-backend-package-inputs-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  mkdir -p layout
  cp -r ${db.src} layout/codetracer
  ln -s ${flake.inputs.codetracer-trace-format} layout/codetracer-trace-format
  python3 -I -B - layout/codetracer/src/db-backend <<'PY'
  import pathlib, sys, tomllib

  def path_deps(manifest):
      tables = [manifest] + list(manifest.get("target", {}).values())
      tables.append({"dependencies": manifest.get("workspace", {}).get("dependencies", {})})
      for table in tables:
          for key in ("dependencies", "dev-dependencies", "build-dependencies"):
              for name, spec in table.get(key, {}).items():
                  if isinstance(spec, dict) and "path" in spec:
                      yield name, spec["path"]
      for member in manifest.get("workspace", {}).get("members", []):
          yield member, member

  root = pathlib.Path(sys.argv[1]).resolve()
  seen, missing, todo = {root}, [], [root]
  while todo:
      crate = todo.pop()
      manifest = tomllib.loads((crate / "Cargo.toml").read_text())
      for name, rel in path_deps(manifest):
          dep = (crate / rel).resolve()
          if dep in seen:
              continue
          seen.add(dep)
          if (dep / "Cargo.toml").is_file():
              todo.append(dep)
          else:
              missing.append(f"{name} ({rel}, needed by {crate.name})")
  if missing:
      sys.exit("db-backend source is missing path dependencies: " + "; ".join(missing))
  print(f"db-backend source holds all {len(seen) - 1} path dependencies")
  PY
  # The native build environment's shell hook puts libs/nim-stew on the
  # ct_emulator Nim path when it is there (nix/backend-native-env.nix).
  if [ ! -d layout/codetracer/libs/nim-stew/stew ]; then
    echo "db-backend source has no libs/nim-stew" >&2
    exit 1
  fi
  touch $out
''
