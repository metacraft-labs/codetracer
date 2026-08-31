<!-- copied as both top-level codetracer repo CONTRIBUTING.md and a contributing page in the docs book  -->

## Contributing

We welcome contributors!

If you want to fix something smaller, feel free to open an issue or a a PR.

For bigger changes it's advised to first open an issue/discussion in the relevant Github repo or to discuss it our team in our [Discord chat server](https://discord.gg/aH5WTMnKHT).

### Contributors guide

Here are some recommendations, however if you want more info, our docs/contributor guide are hosted [on the CodeTracer site](https://contributors-guide.codetracer.com/) !

The guide is written as a set of markdown documents and built using [mdbook](https://rust-lang.github.io/mdBook/) and [mdbook-alerts](https://crates.io/crates/mdbook-alerts) .

You can contribute to the documentation itself, by editing it in `docs/book` and making a pull request. You can iterate on it locally , by cloning the repo, activating it's nix devshell and running `just serve-docs [hostname port]`: it will serve it locally(by default on <http://localhost:3000>).

### Style guide

For Rust, we are using `cargo fmt` to autoformat our code, and `cargo clippy` with some custom allow/deny rules inside the code.
We have a `cargo clippy` check in our CI, but one can also run it locally.

For Nim, we still haven't written down a guide or list of rules and principles that we agree on, so this is something that we hope to do.
We might also link to an existing document.

### Code compiled for both backends

Nim compiles this front end to C and to JavaScript, and a handler that is
correct on one backend can be **absent** on the other while the code reads
identically. That is a whole class, not an incident:

> **`except CatchableError` is not portable.** On the C backend `parseJson`
> raises `JsonParsingError`, a `CatchableError`. On the JS backend it defers to
> V8's `JSON.parse`, which throws a raw `SyntaxError` that no Nim exception
> type matches — so the narrow form catches nothing and the exception escapes.

The guard in `platform/wasm_worker.nim` that exists to stop a malformed worker
payload hanging a caller did exactly this: it handled the case correctly under
`nim c` and **crashed the process** under `nim js`, which is the backend the
renderer ships on. Use a bare `except:` where the failure can originate outside
Nim, and say in a comment why the narrow form is wrong there.

Two habits that catch the rest of the class:

1. **Run both lanes.** `just test-vm` runs `vm-unit` and `vm-unit-js`; a suite
   that only appears in one of them cannot see this. `vm-unit` passed over the
   defect above.
2. **Be suspicious of anything that crosses into a host primitive** — parsing,
   time, randomness, string encoding, number formatting, exceptions. The two
   standard libraries agree on the signature and not always on the behaviour.

The same asymmetry appears in the *shape* of data across a boundary rather than
in errors: see `backend/worker_backend.nim`'s header for an engine that sent
objects one way and JSON strings the other, and a reader that reported a
timeout over an engine that had answered.

### `ui:` views: a template parameter's name leaks into your attribute names

Nim substitutes an `untyped` template argument **wherever the parameter's
identifier appears** — and an accent-quoted attribute name in a `ui:` tree is
made of identifiers. So a parameter whose name is also a token of an attribute,
a class or a `data-` key silently rewrites that name, differently at every call
site.

> **`template renderPanelImpl(r, model, handlers: untyped)` renders
> `` `data-ct-verification-no-model` `` as `data-ct-verification-no-**model**`
> when the caller passes something called `model`, and as
> `data-ct-verification-no-**m**` when the caller passes a local called `m`.**

That is the whole defect. It was found in `isonim_verification_view.nim` and
`isonim_counterexample_view.nim`, whose templates also carried
`` `data-ct-counterexample-model-status` `` and
`` `data-ct-counterexample-model-bindings` ``.

**Nothing failed.** Both expansions compiled. Both rendered a complete tree.
Both carried the *right text*, so every text assertion stayed green — and so did
every attribute assertion, because they all ran against the expansion whose
argument happened to be called `model`.

Two rules, and the second is the one that actually catches it:

1. **Name template parameters so they cannot be tokens of markup.** `mdl`, `hnd`
   — not `model`, `handlers`, `state`, `row`, `item`, `kind`, `id`, `value`,
   `name`, `label`, `index`. Anything you would plausibly write between two
   hyphens in a `data-` key is a live hazard.
2. **Assert attribute names on the *live* tree, not only the pure one.** A view
   that has both a `render*(r, model)` and a `render*Live(r, vm)` entry point
   has two expansions of one template, and **a pure-tree-only assertion cannot
   see this class at all** — it is green by construction, because the pure
   caller's argument is the one named after the parameter. Compare the two
   trees' attribute-name sets and require them equal; that is four lines and it
   is the only thing that fails.

`viewmodel/tests/unit/test_counterexample_session.nim` has that comparison
(`the live tree carries the same attribute NAMES as the pure one`), and
`run-vnm5-render-mutations.py` arm `R19` reproduces the defect in one line so
the naming convention is enforced rather than remembered.

### Shell: the formatter can change what a script means

`shfmt` is a pre-commit hook (`-w -l -ln auto -s`), so it **rewrites** the files
in a commit rather than merely reporting on them. It is a Bash parser, and where
its parse differs from Bash's it silently rewrites working code:

> **An associative-array subscript containing a hyphen is parsed as
> ARITHMETIC.** `${bundle[renderer-electron]}` becomes
> `${bundle[renderer - electron]}` — subtraction, not the key you wrote. Bash
> looks up a key named `renderer - electron`, finds nothing, and yields the
> empty string.

Bash itself is fine with the original: for an array declared `declare -A` the
subscript is a *string*, so the hyphen is just a character. Nothing is wrong
until the formatter touches the file — which means the breakage arrives in
whatever commit next edits the script, attributed to whoever made that edit,
with no relation to what they changed.

`ci/test/renderer-pane-parity.sh` hit this while being written. It is caught
only by **diffing the formatter's output instead of accepting it**; running
`shfmt -w` and committing the result looks identical to a no-op.

`ci/test/renderer-browser-build.sh` still carries the pattern at its
`electron_js=` / `web_js=` assignments. It is not currently broken, and if the
formatter ever rewrites it the gate fails *loudly* — `-z` on the empty value
hits its "an arm did not build" exit. Note what that costs anyway: a confusing
red that blames the build for a formatting change. **A false green is the worse
version of this**, and it is available to any script whose empty-key value flows
into a comparison rather than a guard.

**Rule: keep array subscripts alphanumeric-and-underscore.** Where the natural
key has a hyphen (lane ids like `renderer-electron` do), pass a separate
hyphen-free key alongside it rather than renaming the lane, and say why in a
comment so the next reader does not "tidy" it back.

### Migrating an API that carries errors

One rule, because it has cost us three separate defects in three campaigns:

> **An error-carrying API migrated to a defaulting one satisfies most callers
> and silently breaks the one that guards on a different signal.**

If the old call raised, rejected, or returned an error value, and the new one
returns a default instead, then every caller that checked `len > 0` keeps
working and the caller that checked `isNil` — or `== 0`, or "is the field
present" — silently starts treating a failure as real data. It compiles, the
types line up, and most of the tests pass.

So, before converting such a call site:

1. **Read what every caller branches on**, not how many still compile. If any
   of them distinguishes failure from a legitimate empty / zero / absent value,
   the migration has to preserve the error contract, not just the return type.
2. Preserve it explicitly — `platform_host.ctOrRaise` for callers that already
   handle an exception, or reshape the caller to take the outcome.
3. **Test the failing direction by asserting that it raises or that `ok` is
   false** — never by asserting the result differs from the fallback.
   `check migrated(bad) != ""` passes against the defect it is meant to catch.

`src/frontend/viewmodel/platform/outcome.nim`'s `valueOr` carries the worked
example, at the place the mistake gets made.

### Commits/Pull Requests

We are using [the "Conventional Commits" strategy](https://www.conventionalcommits.org/).

We use or are ok with using more "types", not only those included by default in their official page: e.g. `cleanup:`, `tooling:`, `examples:` etc.

We use `git rebase`, not merge and currently use the github pull requests as the main way to add code. Any pull request would need at least one review
from someone from the CodeTracer team.
