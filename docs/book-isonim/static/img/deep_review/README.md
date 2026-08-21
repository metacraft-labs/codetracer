# Generated screenshots

The `*.png` files in this directory are **generated assets**, not hand-made
ones. The pages of the `deep_review` section serve them from
`/assets/img/deep_review/`.

Regenerate them with:

```bash
just capture-deep-review-assets
```

That builds a real two-commit Noir repository, records it twice with the
shipping `ct record`, collects a real dataset with the shipping
`ct review collect`, opens it with the shipping `ct review`, and photographs the
running window — so the images always show the shipping UI rather than a drawing
of it. It needs a built `ct` (`just build-once`) plus `nargo`, `Xvfb`, `xdotool`
and ImageMagick; if any is missing it fails with a named remedy and a non-zero
status rather than leaving stale images in place.

| File                | Where it is used | What it shows |
| ------------------- | ---------------- | ------------- |
| `review-window.png` | `deep_review/index.md` (Introduction) | The whole review: the VCS panel, the diff tab, and the Agent Activity panel with the roll-up. |
| `diff-tab.png`      | `deep_review/reading.md` | A close-up of the diff tab: the invocation stepper, the loop stepper, the value chips, the expand control. |
| `vcs-panel.png`     | `deep_review/reading.md` | A close-up of the VCS panel — the review's navigation surface: the `Review: <commit>` header, the trace-context selector, the totals, the `Unified Diff` toggle and the changed-file row with its coverage badge. Added by DS-1, when the section split gave that panel a walkthrough of its own and the whole-window shot proved too small to read it in. |

All three come from **one** capture run, so the commit id in the header is the
same picture to picture. Regenerating one image without the others is how they
start disagreeing; the recipe writes all three.

## Why they are checked in

The book is published from CI on every push, and the capture needs an X display
and the Noir toolchain. Making the doc build depend on that would make the docs
unpublishable whenever the capture environment is unavailable — so the images
are committed, and the recipe above is how you refresh them.

`tests/test_nav_order_matches_summary.nim` resolves every `/assets/...` link in
the content against this tree, so a page may only reference an image that
actually exists here; deleting one fails the suite rather than 404ing in a
browser. `tests/test_deep_review_section.nim` closes the other half of the
loop: every image the section references must also be one the capture script
above actually writes, so an image cannot survive here as an orphan that
nothing regenerates.

## Why Noir

The recording is a **materialized** trace, the trace kind the db-backend
collector was added for. DeepReview is not an rr-only feature, and the pictures
in the book should not imply that it is. A native/rr capture would additionally
need an rr-capable machine (`perf_event_paranoid <= 1`).
