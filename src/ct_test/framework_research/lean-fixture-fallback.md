# Lean Fixture Fallback Research

## Detection

- Project markers: `m12-lean.fixture`, `lakefile.lean`, or `lakefile.toml`.
- Source discovery: `.lean`.
- Implemented provider: `lean-fallback`.

## Run Commands

- File fixture: `lean --run <file>`.
- Nix fallback package: `lean4`.

## Source Discovery And Entry Points

- M12 expects a Lean file with a `main` definition for executable fixture support.

## Recording Feasibility

- Recording wraps the Lean runner process with `ct-mcr`.
- This is honest runner-level recording for interpreted/JIT-style execution, not theorem-prover tactic stepping.

## Limitations And Capability Diagnostics

- `canRunSingle=false` and `canRecordSingle=false`.
- No Lean test framework selector is claimed in M12.
- Missing `lean` reports a missing-tool diagnostic.
