## Contributions

We are welcoming contributors! 

If you want to fix something smaller, feel free to open an issue or a a PR!

If you want to make a bigger change, or to add a new feature, please open first an issue, or a discussion in our Github repo,
or discuss it with us in the chat server in Discord.

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
