# Omniscient-DB on-disk size benchmark (P2)

The `ct-bench omniscient-db-size` subcommand drives the
Performance + E2E Coverage campaign's P2 benchmark — per-language
on-disk artefact sizes for the omniscient-DB build flow.

For each fixture program, the bench:

1. Records the program through `ct record` (which routes to the appropriate
   per-language recorder backend internally).
2. Invokes `ct trace omniscient-prep <slice-dir> --mode on` to materialise
   the omniscient artefacts under `meta_dat/`.
3. Measures the on-disk artefact sizes via `std::fs::metadata`.

Output lands in `src/codetracer-bench/target/codetracer-bench/omniscient-db-size/`
in three formats:

- `report.csv` — for spreadsheet ingestion.
- `report.json` — for downstream tooling.
- `report.md` — the human-friendly form (rendered below).

## How to invoke

```bash
# Default: Python + C++ × 3 fixtures each (6 rows).
just bench-omniscient-db-size

# Narrow to a single language.
just bench-omniscient-db-size --languages=python

# Full 10-language matrix (skips per-language when the recorder is absent).
just bench-omniscient-db-size --all-languages
```

Operators on hosts where the recorders live under different binary
names can override per-language via the `RECORDER` env var inside each
fixture's `regenerate.sh`, or via the global `CT_BIN` env var for the
`ct` driver.

## How to read the report

Columns:

| column | meaning |
| --- | --- |
| `id` | `<language>/<fixture name>` |
| `language` | recorder language |
| `run_length_events` | event count from the trace manifest (0 when unavailable) |
| `trace_size_raw` | bytes on disk of the recorded trace |
| `trace_size_compressed` | post-compression bytes (currently same as raw — recorders ship pre-compressed) |
| `omniscient_size_raw` | `meta_dat/memwrites.tc + linehits.tc` bytes |
| `omniscient_size_compressed` | as above (recorders ship pre-compressed) |
| `origin_meta_size_raw` | `meta_dat/originmeta.tc + varwrites.tc + source_exprs.tc + origin-config.toml` bytes |
| `origin_meta_size_compressed` | as above |
| `ratio_omniscient_over_trace` | ratio of omniscient artefacts to the underlying trace |
| `ratio_origin_meta_over_trace` | same for the origin-metadata artefacts |
| `ratio_compressed_over_raw` | post-compression ratio across trace + omniscient |

The ratios are computed at report time from the raw byte columns so
downstream consumers can recompute them with different denominators.

## How to extend the fixture set

Each language has a `src/codetracer-bench/fixtures/omniscient-db-size/<language>/`
directory holding one sub-directory per fixture. To add a fixture:

1. Create `src/codetracer-bench/fixtures/omniscient-db-size/<language>/<name>/`.
2. Add `main.<ext>` with the fixture program.
3. Copy `regenerate.sh` from an existing fixture and adjust the
   recorder env-var name if required.

The bench picks fixtures up automatically — no code changes required.

## SKIP discipline

Each language probe checks for exactly one binary on PATH and emits a
precise sentinel when it's missing:

```
SKIPPED python: codetracer-python-recorder not on PATH
```

The bench never SKIPs broadly. Operators can read the trailing log
output to see exactly which dependency the bench wants.
