# CodeTracer Python Distribution
## TODO: update readme

This package delivers the CodeTracer time-traveling debugger binaries to Python
environments. Wheels are produced per operating system and CPU architecture and
ship the `ct` application together with a thin Python wrapper that locates and
launches the bundled executables.

## Installation

```bash
python -m pip install codetracer
```

### Command line entry points

The package also publishes two console scripts:

* `ct` – invokes the CodeTracer CLI.

Arguments passed to these entry points are forwarded directly to the underlying
binaries.

## Project links

* Documentation: https://docs.codetracer.com
* Issue tracker: https://github.com/metacraft-labs/codetracer/issues

## License

CodeTracer is distributed under the terms of the GNU Affero General Public
License v3.0 or later. See the `LICENSE` file in this directory or the root of
the repository for details.
