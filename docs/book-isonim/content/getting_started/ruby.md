---
title: Ruby
order: 5
---
## Ruby

We currently have partial support for the Ruby programming language

The recorder for Ruby is currently hosted in the [codetracer-ruby-recorder](https://github.com/metacraft-labs/codetracer-ruby-recorder) repo.

## How to launch a program written in Ruby

Adjust the steps below for your use case or run the exact steps to launch the space_ship program which is included with the repo.

1. Navigate to CodeTracer's folder
2. Use ```ct record <path to rb file> [<args>]``` and ```ct replay <name of rb file>``` (or directly ```ct run <path to rb file> [<args>]```)

   Example: ```ct run examples/ruby_space_ship/main.rb```

:::caution
Recording ruby on macOS requires you to install ruby through [homebrew](https://brew.sh), otherwise trying to record ruby programs will fail due to the built-in ruby binary on macOS being more than 7 years old.

Once homebrew is installed, simply install ruby with `user $ brew install ruby`.
:::

## Recording a web application

Rack applications — including Ruby on Rails and Sinatra — are recorded as a
running server rather than a single script, and each HTTP request shows up
in the Request Panel. That has its own guide:
[Live requests — Ruby](/usage_guide/live-requests-ruby).

In short:

```bash
ct record --server --lang ruby -o ./trace -- rails server --port 3000
```

Then `ct replay -t ./trace` in another terminal shows requests as they
arrive.

:::note
Rails support is recent. If you tried Rails with CodeTracer some time ago and
it hung during boot, that was a recorder bug in integer conversion on large
values; it is fixed.
:::
