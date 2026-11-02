# Narrative fixture: a recorded checkout session

`tests/narrate.rs` narrates a real browser session: the checkout page in
`site/`, recorded in headless Chromium by the generic boundary shim of
codetracer-js-recorder.

| File | What it is |
| --- | --- |
| `site/` | The page: an experiment arm on the document element (`data-ct-arms`), labelled controls (`data-ct-label`), an e-mail field checked by a declassifier (`isValidEmail`), two requests and two marks (`ct.mark`) |
| `capture.mjs` | Records the session and writes its boundary log (the shim's `log()`) |
| `checkout.jsbound.log` | The session: add to cart, show details, type a name, an invalid e-mail address, continue, a valid one, continue, pay |
| `checkout-extra-click.jsbound.log` | The same session recorded again with one more click on "Show details" (the test's negative control) |
| `checkout.narrative.json` | The reviewed narrative of `checkout.jsbound.log` (the golden) |

To record the two sessions again, build codetracer-js-recorder
(`npm run build` in its checkout) and run, inside its dev shell:

```sh
node capture.mjs --recorder <codetracer-js-recorder> --variant base \
  --out checkout.jsbound.log
node capture.mjs --recorder <codetracer-js-recorder> --variant extra-click \
  --out checkout-extra-click.jsbound.log
```

Then regenerate the golden with `JSBOUND_UPDATE_GOLDEN=1 cargo test --test
narrate`, and review the difference before keeping it: the golden is what the
test holds the deriver to.
