## Noir

The initial release of CodeTracer has MVP support for the Noir programming language. It has been developed in collaboration with the Blocksense team and currently requires the use of the [Blocksense Noir Compiler](https://github.com/blocksense-network/noir), which is included in the CodeTracer distribution.

We support many of Noir's features, but not all: e.g. we don't support mutable references currently, we don't serialize struct values and some other cases.

We are planning on adding support for the missing features in the future.

## How to launch a program written in noir

Adjust the steps below for your use case or run the exact steps to launch the space_ship program which is included with the repo.

1. Navigate to CodeTracer's folder
2. Run ```ct run <path to your noir program>``` command followed by the path of your noir project folder
2. Use ```ct record <path to your noir program>``` and ```ct replay ct record <path to your noir program>``` (or directly ```ct run ct record <path to your noir program>```)

   Example: ```ct run examples/noir_space_ship```

