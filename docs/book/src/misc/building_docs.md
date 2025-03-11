## Building the documentation

The documenation for codetracer is written in Markdown using [mdbook](https://rust-lang.github.io/mdBook/).
We use some extensions from [GitHub Flavoured Markdown](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax) : specifically alert boxes with [mdbook-alerts](https://crates.io/crates/mdbook-alerts).

To build the documentation run `just build-docs`. If you want to iterate on the documentation for local development, run `just serve-docs [<hostname>] [<port>]` or by going in the docs directory and running `mdbook serve [--hostname <hostname>] [--port <port>]` and a web server will be started, by default on http://localhost:3000 .

The built doc files are stored under `docs/experimental-documentation/build`, while the markdown files are under `docs/experimental-documentation` and its child directories.
