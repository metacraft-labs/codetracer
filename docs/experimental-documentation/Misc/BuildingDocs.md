# Building the documentation
The documenation for codetracer is written in [GitHub Flavoured Markdown](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax) 
that's converted to HTML using [pandoc](https://pandoc.org). This makes the documentation both easy to write, maintain, deploy and build.

To build the documentation run `just build-docs`. If you want to build the documentation for local development, run `just build-docs localhost` and a web server will be started on port `5000`.

The built is stored under `docs/experimental-documentation/build`, while the markdown files are under `docs/experimental-documentation` and its child directories.
