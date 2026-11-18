# The packages' source holds every file a package module embeds at compile time.
#
# nix/packages/default.nix builds the packages from an explicit list of paths,
# leaving out ci/, .github/, docs/ and src/tests/ so that a commit there leaves
# their derivations, and cached outputs, alone. Nim's `staticRead`/`slurp` read
# files at compile time; one that names a file the list leaves out fails only
# the Nix build (`ct agent`'s prompt, docs/agent-prompt/deepreview-evidence.md,
# is why that one file is listed). This checks every Nim module in the package
# source that is not itself a test -- no `tests/` directory in its path, not
# `*_test.nim` or `test_*.nim` -- for a literal `staticRead`/`slurp` path that
# exists in the repository but not in the package source.
# Run by ci/lint/nix.sh.
{
  repo ? ../..,
}:
let
  flake = builtins.getFlake "git+file://${toString repo}?submodules=1";
  packages = flake.packages.${builtins.currentSystem};
  pkgs = flake.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
in
pkgs.runCommand "package-src-completeness-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 -I -B - ${packages.codetracer.src} ${flake.outPath} <<'PY'
  import pathlib, re, sys

  src, repo = (pathlib.Path(a) for a in sys.argv[1:3])
  call = re.compile(r'\b(?:staticRead|slurp)\s*\(?\s*"([^"\n]+)"')
  checked, missing = 0, []
  for module in sorted(src.rglob("*.nim")):
      rel = module.relative_to(src)
      if "tests" in rel.parts[:-1] or rel.name.endswith("_test.nim") or rel.name.startswith("test_"):
          continue
      for target in call.findall(module.read_text(errors="replace")):
          if target.startswith("/") or "$" in target:
              continue
          checked += 1
          wanted = (rel.parent / target)
          parts = []
          for part in wanted.parts:
              if part == "..":
                  if parts:
                      parts.pop()
              elif part != ".":
                  parts.append(part)
          wanted = pathlib.Path(*parts) if parts else pathlib.Path(".")
          if (repo / wanted).exists() and not (src / wanted).exists():
              missing.append(f"{rel}: {target} -> {wanted}")
  if missing:
      sys.exit("the package source leaves out files package modules embed:\n  " + "\n  ".join(missing))
  print(f"the package source holds all {checked} files its modules embed")
  PY
  touch $out
''
