# ADR 0006: Preserve Script Arguments in `ct record`

- **Status:** Proposed
- **Date:** 2025-10-28
- **Deciders:** Codetracer Runtime & Tooling Leads
- **Consulted:** CLI & Tooling WG, Desktop Packaging, QA Automation
- **Informed:** Developer Experience, Support, Product Management

## Context

`ct record` is the canonical entry point for capturing traces from user programs. After the Python recorder was wired into the db-backend (ADR 0005), we expect `ct record <script> [args…]` to behave just like invoking the target runtime directly. Today this breaks down for Python (and any language routed through the db-backend) whenever the recorded script needs its own CLI switches. The Codetracer CLI is built with `confutils`; the `record` command models `<program>` as a positional argument and `<args>` as another `argument` field. When users pass script flags such as `--lf -x` (pytest filters), `confutils` interprets them as additional Codetracer options instead of positional payloads. The command therefore fails early with `Unrecognized option 'lf'`, and there is no reliable escape hatch because `ct record` does not recognise `--` separators or other pass-through affordances.

The db-backend layer already treats every token that appears after the program path as opaque script arguments. The limitation exists entirely in the CLI parser, preventing us from offering parity with `python script.py --flags`. We need to redefine the `record` command contract so that Codetracer options end once the program path is provided and everything that follows is forwarded unchanged to the recorder subprocess, regardless of leading dashes or `=` assignments.

## Decision

We will make `ct record` treat the user program arguments as an opaque tail that bypasses further CLI parsing, matching the behaviour of common record-and-run tooling.

1. **Adopt pass-through semantics in confutils:** Rework the `record` command definition so that once `<program>` is parsed, the remainder of the command line (`recordArgs`) is collected via `restOfArgs`. Confutils will no longer attempt to interpret tokens that begin with `-` or `--`.
2. **Preserve forward compatibility:** Document the updated signature as `ct record [ct options] <program> [--] [program args…]`. The explicit `--` separator becomes optional yet supported, ensuring scripts that rely on leading `--` arguments behave predictably and helping users disambiguate when Codetracer gains new options later.
3. **Guarantee db-backend fidelity:** Keep the existing `db_backend_record` behaviour where the first non-option token is the executable and the rest is forwarded verbatim. Add regression coverage so we do not inadvertently reintroduce option parsing in the backend launcher.
4. **Harmonise higher-level entry points:** Update the UI launcher (`recordWithRestart` / `ct run`) and documentation to reflect the same pass-through guarantees, so scripts recorded through the desktop UI or automation flows accept the exact same arguments.
5. **User-facing validation & help:** Extend CLI help, docs, and error messaging to clarify the new contract, including examples that show both bare and `--`-delimited usage.

## Alternatives Considered

- **Require `--` separator:** Enforcing a hard `--` between Codetracer options and script arguments would solve the immediate bug but break existing invocations (`ct record script.py arg1`) and surprise users who expect parity with `python script.py`. Optional support keeps compatibility while giving users a future-proof escape hatch.
- **Introduce a `ct record --cmd "<command>"` wrapper:** This would allow arbitrary command execution but pushes quoting/escaping complexity onto users and diverges from the single positional program paradigm already relied upon by UI surfaces.
- **Parse and forward known script options individually:** Attempting to whitelist specific flags (e.g., pytest switches) would be brittle, language-specific, and unsustainable as recorder coverage expands.

## Consequences

- **Positive:** Users can invoke `ct record my_tests.py --lf -x` (or similar) and receive an accurate recording without wrapping scripts in shell shims. Automation and CI flows gain better parity with direct runtime invocation. Documentation and training become simpler because tooling behaves “like running the program directly”.
- **Neutral:** Slightly more care is required when adding new Codetracer options to avoid conflicts with commonly-used script flags. Providing `--` as an opt-in delimiter and updating help mitigates this risk.
- **Negative:** None identified; the change relaxes parsing rather than tightening it. We must, however, add regression tests to ensure future refactors do not reintroduce eager option parsing.

## Test Coverage Examples

The following user flows must be captured as regression tests (with supporting harnesses that assert the backend receives the exact argument vector):

- `ct record tests/test_helper.py --lf -x` – pytest-style long and short flags without a delimiter.
- `ct record tests/test_helper.py -- --lf -x` – identical flags guarded by the optional `--` separator.
- `ct record tests/test_helper.py -k=test_case --maxfail=1` – mixed short/long flags, including `=` assignments.
- `ct record tests/test_helper.py -- -weird --fake` – arguments that start with dashes *after* a delimiter to ensure pass-through works even when the first payload token is `--`.
- `ct record tests/test_helper.py` – no additional arguments to confirm baseline behaviour is unchanged.

## Key Locations

- `src/ct/codetracerconf.nim` – redefine the `record` command schema to use `restOfArgs` for program arguments.
- `src/ct/trace/run.nim` & `src/ct/trace/record.nim` – ensure the new argument shape flows through UI launchers and the db-backend bridge.
- `src/ct/db_backend_record.nim` – confirm the backend launcher continues to treat post-program tokens as opaque.
- `docs/**` & `ct --help` output – update usage examples and guidance.
- CLI integration tests (e.g., `ui-tests`, targeted regression tests) – cover representative invocations with leading-dash script arguments.

## Status & Next Steps

- Draft ADR for review (this document).
- Align stakeholders on the CLI contract and documentation updates.
- Execute the implementation plan to update parsing, help text, and regression coverage.
