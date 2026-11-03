# Generated screenshots

The `*.png` files in this directory are **generated assets**, not hand-made
ones. `usage_guide/visual_recordings.md` serves them from
`/assets/img/visual_recordings/`.

Regenerate them with:

```bash
just capture-book-assets
```

That records a real GL trace and drives the real visual-replay player, so the
images always show the shipping UI rather than a drawing of it. It needs a
built `ct_gfx_player` (`codetracer-visual-replay`) and a built `ct_cli`
(`codetracer-native-recorder`); if either is missing it fails with a named
remedy and a non-zero status rather than leaving stale images in place.

## Why they are checked in

The book is published from CI on every push to `main`, and the capture needs a
GPU-capable player plus two recorder siblings. Making the doc build depend on
that would make the docs unpublishable whenever the capture environment is
unavailable — so the images are committed, and this recipe is how you refresh
them.

Two things keep that from rotting into "nobody regenerates these":

- `tests/test_nav_order_matches_summary.nim` resolves every `/assets/...`
  link against this tree, so a page may only reference an image that actually
  exists here. Deleting one fails the suite rather than 404ing in a browser.
- The recipe above is the single documented way to produce them, and it is
  wired into the reprobuild graph alongside the book build.

This file replaced a `PLACEHOLDERS.txt` which said the real captures went to
`docs/book/src/generated/visual_recordings/` — the *old* mdBook's output
directory, which is not checked in and which this book never reads. The
placeholder images were shipped as if they were the real thing.
