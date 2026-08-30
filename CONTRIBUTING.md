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
