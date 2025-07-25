## Ruby

We currently have partial support for the Ruby programming language

The recorder for Ruby is currently hosted in the [codetracer-ruby-recorder](https://github.com/metacraft-labs/codetracer-ruby-recorder) repo.

## How to launch a program written in Ruby

Adjust the steps below for your use case or run the exact steps to launch the space_ship program which is included with the repo.

1. Navigate to CodeTracer's folder
2. Use ```ct record <path to rb file> [<args>]``` and ```ct replay <name of rb file>``` (or directly ```ct run <path to rb file> [<args>]```)

   Example: ```ct run examples/ruby_space_ship/main.rb```

> [!CAUTION]
> Recording ruby on macOS requires you to install ruby through [homebrew](https://brew.sh), otherwise trying to record ruby programs will fail due to the built-in ruby binary on macOS being more than 7 years old.
> 
> Once homebrew is installed, simply install ruby with `user $ brew install ruby`.
 
## Note: Ruby on rails programs are currently not supported.
