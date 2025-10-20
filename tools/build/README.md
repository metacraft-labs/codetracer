# Codetracer Build Driver

`build_codetracer.sh` is the canonical entry point for compiling Codetracer
artefacts. It wraps the Nim compiler with shared flag bundles so every build
surface (Tup, Nix, AppImage, non-Nix packaging, CI) can delegate to the same
logic instead of re-declaring command lines.

## Usage

```bash
tools/build/build_codetracer.sh --target ct --profile debug --output-dir ./out/bin
tools/build/build_codetracer.sh --target db-backend-record --profile release --extra-define builtWithNix --output-dir ./dist/bin
tools/build/build_codetracer.sh --target js:index --output ./out/js/index.js --dry-run
tools/build/build_codetracer.sh --target js:middleware --output ./out/js/middleware.js --extra-define ctInCentralExtensionContext
tools/build/build_codetracer.sh --target ct-wrapper --output ./out/bin/ct
```

### Key flags

- `--target` – identifies the artefact to build (`ct`, `ct-wrapper`,
  `db-backend-record`, `js:index`, `js:server-index`, `js:subwindow`,
  `js:ui`, `js:middleware`).
- `--profile` – switches between `debug` and `release` flag bundles
  (default: `debug`).
- `--output-dir` – location for the generated binary or JS file. Defaults to
  `build/<profile>/bin` for binaries and `build/<profile>/js` for JS targets.
- `--output` – explicit output file path; overrides the default directory/name
  and is useful when integrating with build tools like Tup that expect a
  specific location.
- `--extra-define` / `--extra-flag` – append additional `-d:<value>` or raw
  Nim flags without mutating the shared defaults.
- `--dry-run` – prints the resolved command without executing Nim; useful
  for tests or integration planning.

## Tests

Smoke tests live in `tools/build/tests`. Run them with:

```bash
tools/build/tests/dry_run_test.sh
```

The tests rely solely on dry-run output, so they complete quickly without
requiring Nim toolchains or other build dependencies.
