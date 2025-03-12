## DB backend

### Languages

The DB backend is currently used for interpreted languages, like scripting and blockchain/zero knowledge languages:

1. [Noir](./db-backend/noir.md)
1. [Ruby](./db-backend/ruby.md)
1. [Python(prototype not finished yet)](./db-backend/py.md)
1. [Lua(not done: just a plan)](./db-backend/lua.md)
1. [small(a toy interpreter for dogfooding)](./db-backend/small.md)

If you're interested in db-backend support for those languages or for now ones, you can discuss with us on our [GitHub issue tracker](https://github.com/metacraft-labs/codetracer/issues),
in the [GitHub repo discussions forum](https://github.com/metacraft-labs/codetracer/discussions) or in our [discord chat server](https://discord.gg/aH5WTMnKHT). We welcome contributors!

### Additional directions

However we're exploring using this method for emulators(and conversely, for emulating native languages) in the future.

Also, languages can have both native(AOT) and interpreted implementations: 
so we can more easily support e.g. interpreters/VM-s of certain languages with this backend currently.

### Implementation

As the name suggests, this backend is implemented as a database. Due to its properties, this backend provides
a more complete feature set - one of the reasons it was ready first.

For each language, we define a tracer, which instruments or hooks into the interpreter, VM or program and 
records all the data, that we need in a trace folder. 

We postprocess and index that trace into a database-like structure. Currently this happens in the beginning of the replay.
For now the data in the database is represented by a runtime-only Rust structure, however
we plan on storing it as a file, which can be memory-mapped and on separating the postprocessing/indexing step as 
an optionally independent action.


