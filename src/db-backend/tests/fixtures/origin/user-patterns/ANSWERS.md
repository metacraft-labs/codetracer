# Expected Origin Chains — user-patterns fixture

This fixture exercises the recorder-time pattern discovery + trace
embedding flow described in spec §7.4 (Value Origin Tracking GUI spec,
"User-defined patterns").

The program at `program/main.py` calls `forward(payload)` from the
faux library at `faux-library/faux_lib.py`. The faux library ships
`.codetracer/origin-patterns.toml`, which the recorder copies into the
recorded trace at `meta_dat/origin-patterns/faux_lib/origin-patterns.toml`.

Three override layers may be active when an origin query runs against
the recorded trace's local `result`:

| Layer | Source                                                                  | Effect                                                                                                                         |
| ----- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 1     | `meta_dat/origin-patterns/_overrides.toml` (trace-local)                | The committed `_overrides.toml` is empty in M0 — no effect.                                                                    |
| 2     | `home-overrides/origin-patterns.toml` (personal overrides)              | Has a matching `[[forwarder]]` rule that **takes precedence over the embedded faux_lib pattern**; description differs.         |
| 3     | `meta_dat/origin-patterns/faux_lib/origin-patterns.toml` (embedded lib) | Original faux-library pattern marking `forward($value)` as TrivialCopy with continuation `$value`.                             |
| 4     | Built-in catalogue (spec §7.1, §7.3)                                    | Default rules; without any override the call to `forward()` would default to Computational (single-arg call transforms input). |

## Expected chain — query target `result` at the `print(result)` line of `main`

### Default replay (no `_overrides.toml`, no personal overrides)

Per the embedded faux_lib pattern (layer 3 active):

```
hop 0: target=result   rhs=forward(payload)   OriginKind=TrivialCopy   classification="user-defined forwarder"
                                                                       pattern_provenance="faux_lib: faux_lib.forward returns its argument unchanged — trivial copy"
                                                                       continuation=payload
hop 1: target=payload  rhs=42                 OriginKind=Literal        terminator=Literal(int, value=42)
```

**Termination:** `Literal` at `payload = 42`.

### Replay with personal-overrides loaded (`HOME=<fixture>/home-overrides`)

Layer 2 wins because it matches first; layer 3 is shadowed:

```
hop 0: target=result   rhs=forward(payload)   OriginKind=TrivialCopy   classification="user-defined forwarder"
                                                                       pattern_provenance="personal: Personal override — forward() forwards its argument (matches embedded faux_lib pattern; takes precedence)"
                                                                       continuation=payload
hop 1: target=payload  rhs=42                 OriginKind=Literal        terminator=Literal(int, value=42)
```

Chain shape is identical; the `pattern_provenance` annotation surfaced
by the State Pane's "Show pattern provenance" affordance differs.

### Replay with trace-local override active

To exercise this, uncomment the `[[computational]]` block in
`_overrides.toml`. Layer 1 then takes precedence and the chain
terminates at the call expression:

```
hop 0: target=result   rhs=forward(payload)   OriginKind=Computational
                                              pattern_provenance="trace-local: Local override — treat forward() as a transformation"
                                              operand_snapshots = [{ name: "payload", value: 42 }]
                                              terminator=Computational(expr="forward(payload)")
```

**Termination:** `Computational`. The chain does NOT recurse into
`payload`; its snapshot value is exposed via operand snapshots.

### Replay with default rules only (no embedded, no overrides — sanity baseline)

If both layer 2 and layer 3 are unavailable (M0 will exercise this with
a stripped-down recorder run that does not embed the faux_lib pattern):

```
hop 0: target=result   rhs=forward(payload)   OriginKind=Computational
                                              operand_snapshots = [{ name: "payload", value: 42 }]
                                              terminator=Computational(expr="forward(payload)")
```

## Notes on M0 readiness

- The `_overrides.toml` file lives next to the source in M0; later
  milestones MUST copy it into the recorded trace's
  `meta_dat/origin-patterns/_overrides.toml` location at record time
  (or via a separate `ct trace insert-override` invocation).
- The recorder-time embedding of `.codetracer/origin-patterns.toml` is
  not yet wired (M2/M3 deliverable). M0 ships the source + override
  files + ANSWERS.md so subsequent milestones can land the embedding
  step against a fixed scenario.
- The `home-overrides/origin-patterns.toml` file is consumed via
  `HOME=$(pwd)/home-overrides codetracer-shell replay ...` in later
  milestones; the test harness symlinks
  `$HOME/.config/codetracer/origin-patterns.toml` to this file.
