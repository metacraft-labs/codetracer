# The Python interpreter this repository builds against.
#
# THIS FILE STATES NO VERSION, AND MUST NOT.
#
# The version is owned by `codetracer-python-recorder`, because that is the
# repo that produces the ABI-locked artefact: a PyO3 extension module
# (`codetracer_python_recorder.cpython-312-*.so`) loads into exactly one
# CPython minor version. It declares that version in its own
# `.python-version`, and publishes it as `lib.python` from its flake. This
# file reads that declaration through the flake input this repo already has.
#
# The inversion that caused the bug was the other way round. `ci-base.nix`
# called
#
#     inputs."codetracer-python-recorder".lib.mkCodetracerPackages pkgs pkgs.python312
#
# — the CONSUMER telling the PRODUCER which interpreter to build for. That
# only ever works while the two literals agree, and there were nine of them
# across four .nix files here, plus two more in a shell script and two more in
# a Windows workflow. They stopped agreeing:
#
#   * `pkgs.python3Packages.flake8` / `.distutils` (ci-base.nix, armShell.nix)
#     propagate nixpkgs' DEFAULT interpreter, 3.13.12 on the current pin, and
#     sat ABOVE `pythonWithRecorder` in the package list, so 3.13 won the PATH
#     search:
#
#       $ which -a python3
#       /nix/store/sdfy…-python3-3.13.12/bin/python3       <- flake8 / distutils
#       /nix/store/zh6n…-python3-3.12.13-env/bin/python3   <- the intended pin
#
#   * `main.nix` then built `.python-recorder-venv` with a bare `python3 -m
#     venv`, got 3.13, and `ct record x.py` died with
#
#       error: Python module `codetracer_python_recorder` is not installed
#              for interpreter: …/.python-recorder-venv/bin/python
#
#     taking the `record-python-happy-path` E2E edge with it. No path wiring
#     can bridge an ABI split.
#
# Now there is one declaration and every site here derives from it. To change
# the version, edit `codetracer-python-recorder/.python-version` and update
# this repo's `flake.lock`; `scripts/test-python-version-alignment.sh` fails
# if anything here disagrees with what the input declares.
#
# WHAT THIS DOES NOT REACH — stated because a single source that silently
# covers half the product is the same defect it is meant to fix:
#
#   * `.github/workflows/codetracer.yml`'s two `actions/setup-python@v5` steps
#     (the `origin-dap-windows-*` lanes) carry the version as a YAML literal.
#     `setup-python` runs BEFORE the recorder is checked out in those jobs, so
#     it cannot read the file. It is therefore CHECKED rather than derived:
#     `scripts/test-python-version-alignment.sh` (H1) fails when the literal
#     and the declaration disagree.
#   * `codetracer/env.ps1` — the native-Windows DIY environment — provisions no
#     Python at all (zero occurrences of the word). On that lane `ct record
#     x.py` resolves an interpreter via `src/ct/trace/record.nim:52-78`:
#     CODETRACER_PYTHON_INTERPRETER / PYTHON_EXECUTABLE / PYTHONEXECUTABLE /
#     PYTHON, else `python3` / `python` / `py` from PATH — i.e. the developer's
#     system interpreter, unpinned and unchecked, with the recorder module
#     installed by hand if at all. That lane has no Python recorder
#     provisioning today; giving it one is separate, queued work and is
#     recorded as such in codetracer-specs.
{
  pkgs,
  inputs,
}:
let
  # The producer's declaration. See
  # codetracer-python-recorder/nix/python.nix for why the source of truth is a
  # plain `.python-version` file (uv and env.ps1 read it too, and neither can
  # read nix).
  declared = inputs."codetracer-python-recorder".lib.python;
in
{
  # "3.12" and "cpython-312", straight from the producer.
  inherit (declared) version abiTag nodot;

  # The interpreter, resolved out of THIS repo's package set so it links
  # against the same glibc as everything else built here, while keeping the
  # minor version the producer declared.
  package = declared.packageFor pkgs;

  # That interpreter's package set. Use this instead of `pkgs.python3Packages`,
  # which follows nixpkgs' default and will drag a second, different Python
  # onto the PATH — the mechanism of the original defect.
  pythonPackages = (declared.packageFor pkgs).pkgs;

  # The recorder packages, built by the producer for its own declared
  # interpreter. Replaces `mkCodetracerPackages pkgs pkgs.python312`, which was
  # this repo asserting a version at the repo that owns it.
  recorderPackages = inputs."codetracer-python-recorder".lib.mkCodetracerPackagesDefault pkgs;

  # Put tools that are built for ANOTHER interpreter (pre-commit and its
  # Python hooks, awscli2, pax-utils' lddtree: nixpkgs' default Python, 3.13
  # on the current pin) on a dev shell's PATH without letting that interpreter
  # into the shell.
  #
  # Listed directly in `packages`, such a tool propagates its interpreter, and
  # every interpreter's nixpkgs setup hook defines a function named
  # `addPythonPath` that adds `lib/python3.N/site-packages` of ITS version for
  # every input of the shell. The definition sourced last replaces the others,
  # so one 3.13 tool can turn PYTHONPATH into 3.13 site-packages only:
  # devShells.default had 25 such entries and none for the pin, and the
  # pinned interpreter imported pytest from the 3.13 copy, since PYTHONPATH is
  # searched ahead of its own site-packages.
  #
  # The tools are wrapped executables that find their own modules, so their
  # `bin/` is all a shell needs. A buildEnv of `/bin` alone has no
  # `nix-support/`, hence no propagated inputs and no setup hooks. It links
  # only the listed packages' own executables, so the interpreter they carry
  # stays off PATH as well. `scripts/test-python-version-alignment.sh` (J)
  # fails a shell whose PYTHONPATH names another minor version.
  binariesOnly =
    name: drvs:
    pkgs.buildEnv {
      inherit name;
      paths = drvs;
      pathsToLink = [ "/bin" ];
    };
}
