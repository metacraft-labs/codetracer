# Variable Rename List

Minified JavaScript bundles strip identifier names — `function add(left, right)` becomes `function a(b,c)`, and your debugger watch pane shows `a = [1,2,3,4,5]` instead of `array = [1,2,3,4,5]`.

When the bundle ships a [source map V3](https://sourcemaps.info/spec.html) with a populated `names` field, CodeTracer's [server-side sourcemap translation](#sourcemap-translation-pipeline) recovers the original names for free.

When the bundle does **not** ship a sourcemap, or its `names` table is missing the binding you care about, you can supply a **rename list** — a small TOML file that maps minified names back to readable ones.  The replay-server loads the list at trace open and applies it whenever it surfaces a variable name to the UI.

This document covers:

* [TOML schema](#toml-schema)
* [Where the file lives](#where-the-file-lives)
* [Composition rules](#composition-rules)
* [Environment variables](#environment-variables)
* [Caveats](#caveats)

## TOML schema

```toml
# Optional metadata.  Reserved for future schema bumps; the current
# parser accepts and surfaces these fields without enforcing them.
[meta]
version = "1"
comment = "lodash 4.17.21 minified bundle"

# Per-file [[rename]] entries.  Each maps a minified variable name to
# a human-readable one.  `scope` defaults to "global" — set to
# "function:<funcname>" or "block:L<line>" to constrain.

[[rename]]
file = "lodash.min.js"     # required — recorded path (relative or absolute)
scope = "global"           # optional — defaults to "global"
from = "e"                 # required — minified binding name
to = "array"               # required — readable name shown by the UI

[[rename]]
file = "lodash.min.js"
scope = "function:chunk"
from = "t"
to = "result"

[[rename]]
file = "lodash.min.js"
scope = "block:L42"
from = "f"
to = "iteration_index"
```

### Required fields

| Field    | Type            | Description                                                              |
|----------|-----------------|--------------------------------------------------------------------------|
| `file`   | string          | Path the recording observed.  Either the basename (`lodash.min.js`) or an absolute path; the loader matches both. |
| `from`   | string          | The minified binding name as it appears in the recorded trace.           |
| `to`     | string          | The readable name the UI should show in its place.                       |

### Optional fields

| Field    | Type            | Default      | Description                                                                                                 |
|----------|-----------------|--------------|-------------------------------------------------------------------------------------------------------------|
| `scope`  | string          | `"global"`   | Lookup scope.  Recognised values: `"global"`, `"function:<funcname>"`, `"block:L<line>"`, or `"block:<n>"`.  |

### Parser tolerance

* Unknown top-level tables (other than `[meta]`) and unknown keys inside `[[rename]]` are **logged at warn level and skipped** — a typo on one key (e.g. `flie = "x"` next to a correct `file = "lodash.min.js"`) does not drop the rename.
* Missing required fields (`file`, `from`, `to`) produce a typed `MissingField` error and refuse to load the list.
* Duplicate `(file, scope, from)` triples produce a typed `DuplicateEntry` error.

## Where the file lives

The replay-server looks for the rename list in this order:

1. The path passed via the CLI flag `--rename-list <path>` on `replay-server dap-server`.
2. The path passed via the DAP `launch` argument `renameList`.
3. The conventional sibling location `<recording-dir>/renames.toml`.

When none of those resolve to an existing file, no rename list is installed and only the sourcemap `names[]` data is consulted (see [composition rules](#composition-rules) below).

### CLI flag

```sh
replay-server dap-server --rename-list ~/recordings/my-trace/renames.toml --stdio
```

The CLI flag applies to **every** trace the server opens during its lifetime.  Per-launch DAP `renameList` arguments override the CLI default on a per-trace basis.

### Sibling lookup

```text
my-recording/
├── trace.ct
├── meta_dat/
├── renames.toml       <-- picked up automatically at trace open
└── ...
```

No flag needed — the loader probes for `renames.toml` next to the trace folder at trace open.

## Composition rules

When the UI requests the name for a recorded binding, the resolver consults three sources in order:

1. **User rename list** (this file).  Lookup is scope-aware:
   * A `Scope::Function(name)` hint matches a `function:<name>`-scoped entry first, then falls back to a `global` entry.
   * A `Scope::Block(line)` hint matches a `block:L<line>`-scoped entry first, then falls back to a `global` entry.
   * A `None` / unknown scope hint matches `global` entries only — function- and block-scoped entries are intentionally narrower.
2. **Sourcemap V3 `names[]` array** (from [§P3](#sourcemap-translation-pipeline) translation).  When the sourcemap declares an entry for the minified name, the resolver echoes the recorded name back as confirmation that the bundle preserved a known original.
3. **`None`** — the recorded name flows through unchanged.

**Precedence on conflict**: the user rename list always wins.  If you map `e -> userId` in `renames.toml` and the bundle's sourcemap names `e` as `e` (or anything else), the UI shows `userId`.

## Environment variables

| Variable                  | Default | Effect when set to one of `0`/`off`/`false`/`no`                                                 |
|---------------------------|---------|--------------------------------------------------------------------------------------------------|
| `CT_RENAME_LIST`          | on      | Disables the rename-list loader entirely — even an explicit `--rename-list` path is ignored.     |
| `CT_SOURCEMAP_TRANSLATION`| on      | Disables [§P3](#sourcemap-translation-pipeline) sourcemap translation (separate kill switch).    |
| `CT_AUTOFORMAT`           | on      | Disables the [§P4](#sourcemap-translation-pipeline) auto-format fallback for sourcemap-less minified sources, **and** the [§P6.2](#sourcemap-translation-pipeline) recorder-side pre-format hook. |
| `CT_AUTOFORMAT_THRESHOLD` | 500     | Override the average-line-length heuristic used by both the recorder pre-format and the replay-server fallback to decide whether a source looks minified.  Integer ≥ 1. |

The four kill switches are independent.  Turning off `CT_RENAME_LIST` does not affect sourcemap translation or auto-format.

## Auto-format pipeline (where formatting happens)

There are **two** places minified-source formatting can run, depending on which recorder produced the trace:

* **Recorder-side (P6.2, recommended).**  Recorders from version 0.2.0 onward (e.g. `codetracer-js-recorder`) detect minified sources at record start, shell out to `prettier` (JavaScript) / `black` (Python) once, and bake the formatted view + a Source Map V3 sourcemap (formatted → original) into the trace under `<trace>/files/<file>.fmt.js{,.map}`.  The replay-server's existing [§P3](#sourcemap-translation-pipeline) sourcemap path discovers the `.map` sibling and translates positions with no replay-time subprocess.
* **Replay-server-side (P4, fallback).**  For traces produced by older recorders, the replay-server lazily formats minified sources at trace open, caching the result under the trace's cache directory.  The behaviour is identical from the UI's perspective; the only difference is *when* the formatter runs (record time vs. view time) and how it's cached.

The same `CT_AUTOFORMAT` env var disables both — useful when you want to inspect the raw minified source.  Disabling autoformat on a trace that already carries a `.fmt.js` sibling is a no-op (the formatted view is already on disk; the env var only gates the lookup pipeline).

The JS recorder exposes a CLI flag `--no-autoformat` that disables the recorder-side hook for a single invocation, falling back to the P4 lazy path at view time.

## Caveats

* **Render-time only.**  The rename list is applied when the value-stream renderer surfaces a binding to the UI.  The recorded trace itself is **not** rewritten — every recorded variable name stays in its original (minified) form on disk.  Re-opening the same trace with a different rename list yields different rendered names.
* **No schema/format change.**  Adding a rename list does not bump the trace format or require the recorder to be aware of it.  Any trace produced by any recorder version works with any rename list.
* **Origin tracking unchanged.**  Variable-origin chains (the §3 of the spec) continue to look up by the recorded variable id, not by the rendered name.  Renaming a binding does not break the origin index.
* **Scope hints are best-effort.**  The resolver computes a scope hint from the surrounding call's function name and the current step's line.  When neither is available (e.g. the step has no associated path), only the global-scope user entries and the sourcemap `names[]` table are consulted.

## See also

* [Source Map V3 spec](https://sourcemaps.info/spec.html) — the format the §P3 translation consumes.
* [Value-Origin Tracking](./value-origin-tracking.md) — the parallel pipeline that recovers value provenance independently of binding names.

<a id="sourcemap-translation-pipeline"></a>
*§P3 (sourcemap translation), §P4 (replay-side auto-format fallback), §P5 (this document), and §P6.2 (recorder-side auto-format hook) are milestones of the **Column-Aware Tracing & Source Deminification** campaign; the milestones spec lives at `codetracer-specs/Planned-Features/Column-Aware-Tracing-And-Deminification.milestones.org`.*
