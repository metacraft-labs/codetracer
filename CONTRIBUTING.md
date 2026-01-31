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

### Commits/Pull Requests

We are using [the "Conventional Commits" strategy](https://www.conventionalcommits.org/).

We use or are ok with using more "types", not only those included by default in their official page: e.g. `cleanup:`, `tooling:`, `examples:` etc.

We use `git rebase`, not merge and currently use the github pull requests as the main way to add code. Any pull request would need at least one review
from someone from the CodeTracer team.
