# Generated screenshots

The `*.png` files in this directory are **generated assets**, not hand-made
ones. `usage_guide/deep_review.md` serves them from
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

| File                | What it shows                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| `review-window.png` | The whole review: the VCS panel, the diff tab, and the Agent Activity panel.                       |
| `diff-tab.png`      | A close-up of the diff tab: the invocation stepper, the loop stepper, the value chips, the expand control. |

## Why they are checked in

The book is published from CI on every push, and the capture needs an X display
and the Noir toolchain. Making the doc build depend on that would make the docs
unpublishable whenever the capture environment is unavailable — so the images
are committed, and the recipe above is how you refresh them.

`tests/test_nav_order_matches_summary.nim` resolves every `/assets/...` link in
the content against this tree, so a page may only reference an image that
actually exists here; deleting one fails the suite rather than 404ing in a
browser.

## Why Noir

The recording is a **materialized** trace, the trace kind the db-backend
collector was added for. DeepReview is not an rr-only feature, and the pictures
in the book should not imply that it is. A native/rr capture would additionally
need an rr-capable machine (`perf_event_paranoid <= 1`).
