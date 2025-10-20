
# Build & Packaging Notes

Codetracer now routes every Nim compilation through the shared driver located at
`tools/build/build_codetracer.sh`. The script understands each artefact (CLI
binary, db backend helper, tester, JS bundles, etc.), applies the canonical flag
sets, and accepts environment-specific overrides via `--extra-define` and
`--extra-flag`.

Typical examples:

```bash
# Debug CLI build to the default staging directory
tools/build/build_codetracer.sh --target ct

# Release tester binary with a custom nimcache path
tools/build/build_codetracer.sh \
  --target tester \
  --profile release \
  --output ./dist/bin/tester \
  --nimcache /tmp/ct-nim-cache/tester

# UI bundle consumed by the VS Code extension
tools/build/build_codetracer.sh \
  --target js:ui-extension \
  --output ./dist/ui.js
```

All developer scripts (`just build-ui-js`, `build_for_extension.sh`), Tupfiles,
and packaging flows (non-Nix, AppImage, Nix) delegate to this driver, so manual
commands should do the same to avoid configuration drift.
