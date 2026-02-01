# rubytracer

very small experiment ruby tracing

```bash
bin/rubytracer <rspec>
```

Currently implemented just using the tracepoint ruby api. Some investigation
in directly doing this with gdb + Ruby VM shows it shouldn't be too hard, but
that server as a quick pre-experiment.

## infer types from trace

```bash
bin/rubytracer ../ruby-project/spec/ruby_spec.rb
ruby ../ruby-project/spec/x.rb
```

```ruby
Ruby::DSL:
  instance:

  class:
    <Symbol> -> <Array[<<Fixnum> | <type Ruby::Node> | <Symbol>>]> -> <type Ruby::Node>
    def n(kind, children)

    <type Ruby::Node> -> <<type Ruby::RObj>?>
    def run(ast)

    <Fixnum> -> <type Ruby::RObj>
    def rint(value)


Ruby::Node:
  instance:
    <Symbol> -> <Array[<<Fixnum> | <type Ruby::Node> | <Symbol>>]> -> <type Ruby::Node>
    def initialize(kind, children)

  class:


Ruby::Env:
  instance:
    <generic Hash> -> <type Ruby::Env>
    def initialize(values)

    <Symbol> -> <None>
    def [](label)

  class:


Ruby::Runner:
  instance:
    <type Ruby::Node> -> <<<type Ruby::RObj> | R::None>?>
    def run(ast)

    <type Ruby::Node> -> <type Ruby::Node> -> <<type Ruby::RObj>?>
    def run_binary_add(a, b)

    <Fixnum> -> <type Ruby::RObj>
    def run_int(value)

    <Symbol> -> <None>
    def run_var(name)

    <<type Ruby::RObj>?>
    def run_module()

  class:


Ruby::RObj:
  instance:
    <Symbol> -> <Hash[<Symbol> <Fixnum>]> -> <type Ruby::RObj>
    def initialize(type, values)

    <Fixnum>
    def value()

  class:
```

The currently used type "system" is very simple: it has

* `atomic` and `class` types that
  correspond to builtin types like String and to classes (currently no real difference)
* `none` type for nil
* `union`: `A | B` for supporting several possible
* `generic`: currently only matching empty arrays
* `concrete`: concretizing generic bases with real types
* `optional`: `A?` when it can be A or nil

We also unify concrete types with unifiable params.
It's probably not very good for a language like Ruby where something more similar to
duck typing like some form of structural typing will be better. However it's sufficient for demonstration in that simple prototype

We rewrite the spec so we can call the code in the `it` and we trace it and analyze it in
`trace.rb`.
