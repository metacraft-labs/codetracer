## Noir

The initial release of CodeTracer has MVP support for the Noir programming language. It has been developed in collaboration with the Blocksense team and currently requires the use of the [Blocksense Noir Compiler](https://github.com/blocksense-network/noir), which is included in the CodeTracer distribution.

We support many of Noir's features, but not all: e.g. we don't support mutable references currently, we don't serialize struct values and some other cases.

We are planning on adding support for the missing features in the future.

## How to Trace a Noir Program

Before tracing your Noir program, you must compile it and provide the inputs. CodeTracer expects your project to have a `Prover.toml` file containing the inputs for your program.

1.  Navigate to your Noir project's directory.
2.  Generate a `Prover.toml` file:
    ```sh
    nargo check
    ```
3.  Edit the necessary inputs in your `Prover.toml` file.

Once your project is ready, you can use CodeTracer's commands from the CodeTracer directory.

### Running a Program (`ct run`)

This command executes your Noir program and displays the visual trace in the CodeTracer UI. This is the most direct way to see your code's execution.

To run the `noir_space_ship` example included with CodeTracer:
```sh
# Make sure you are in the root CodeTracer directory
ct run examples/noir_space_ship
```

### Recording a Trace (`ct record`)

This command runs your program and saves its execution trace.

```sh
ct record examples/noir_space_ship 
```

### Replaying a Trace (`ct replay`)

This command loads a previously recorded trace and displays it in the CodeTracer UI.

```sh
# First, record a trace if you haven't already
ct record examples/noir_space_ship

# Then, replay it
ct replay
```
You will be asked to choose which trace to replay from a list of recent traces.