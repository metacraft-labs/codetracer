
tracer
-----------------

ruby tracer MOVED to a separate repo https://github.com/metacraft-labs/codetracer-ruby-recorder

original readme:

a very early version of a ruby codetracer tracer, that records data about
a running ruby program which is later used to simulate a limited replay of it
in codetracer.

### usage

```bash
ruby trace.rb <ruby-program>
# -> trace.json
# and some debugging output currently
# TODO more options

# or
python3 trace.py
# -> trace.json
```

### run example

```bash
# enter codetracer dir, with enabled direnv
# so you have ruby from our nix shell in PATH
cd src/ruby-tracer
ruby trace.rb calc.rb
cat trace.json
# ..
```

### in codetracer

it should be callable by codetracer with
```bash
ct record <path to ruby-program>
ct replay <ruby-program-name>
```

not yet integrated fully for python

### TODO/problems

* optimizations
* cleanup code
* support more kind of ruby values: only several simples types supported currently
* others
