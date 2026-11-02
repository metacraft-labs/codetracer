# Exercise the evaluated package source and check tools in a real sandbox.
# No stubs: the package build separately compiles and runs the Rust tests.
{
  repo ? ../..,
}:
let
  # Match the package build's Git source, including vendored Nim dependencies;
  # a path flake would also copy concurrently changing Cargo build outputs.
  flake = builtins.getFlake "git+file://${toString repo}?submodules=1";
  packages = flake.packages.${builtins.currentSystem};
  backend = packages.backend-manager;
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
in
pkgs.runCommand "backend-manager-package-inputs-test"
  {
    # buildRustPackage merges nativeCheckInputs into nativeBuildInputs when
    # doCheck is enabled; use the evaluated sandbox inputs, including hooks.
    nativeBuildInputs = backend.nativeBuildInputs;
  }
  ''
    # Every path dependency the crate's manifest declares, and every one
    # theirs declare in turn, must be in the package source: a dependency
    # added to Cargo.toml but not copied there breaks only the Nix build.
    # Read from the manifests rather than listed here, so a new one cannot
    # be forgotten in both places at once.
    python3 -I -B - "${backend.src}/codetracer/src/backend-manager" <<'PY'
    import pathlib, sys, tomllib

    def path_deps(manifest):
        tables = [manifest]
        tables += list(manifest.get("target", {}).values())
        for table in tables:
            for key in ("dependencies", "dev-dependencies", "build-dependencies"):
                for name, spec in table.get(key, {}).items():
                    if isinstance(spec, dict) and "path" in spec:
                        yield name, spec["path"]

    root = pathlib.Path(sys.argv[1])
    seen, missing, todo = set(), [], [root]
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
        sys.exit("backend-manager source is missing path dependencies: " + "; ".join(missing))
    print(f"backend-manager source holds all {len(seen)} path dependencies")
    PY
    # The script executor security tests copy and import the real API, rather
    # than a stand-in, from this layout relative to CARGO_MANIFEST_DIR.
    python3 -I -B - ${backend.src}/codetracer/python-api <<'PY'
    import pathlib
    import sys
    api = pathlib.Path(sys.argv[1])
    assert (api / "codetracer" / "__init__.py").is_file(), f"missing real Python API: {api}"
    sys.path.insert(0, str(api))
    import codetracer
    assert callable(codetracer.open_trace)
    PY
    # The source-confinement integration test drives the real replay server.
    replayServer="${backend.CODETRACER_REPLAY_SERVER_CMD or ""}"
    if [ ! -x "$replayServer" ]; then
      echo "backend-manager checks require a real replay-server executable" >&2
      exit 1
    fi
    "$replayServer" --help >/dev/null
    recorder="${backend.CODETRACER_CT_MCR_CMD or ""}"
    if [ ! -x "$recorder" ]; then
      echo "backend-manager checks require a real ct-mcr executable" >&2
      exit 1
    fi
    "$recorder" --help >/dev/null
    touch "$out"
  ''
