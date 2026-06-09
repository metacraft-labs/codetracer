# Visual Recordings

Visual recordings capture graphics API activity together with the native program execution trace. They are used by the CodeTracer GUI to replay rendered frames, scrub draw calls, inspect pixel history, and debug shader execution.

This feature is built on the MCR recorder and the visual replay player:

1. `ct record --use-interpose` records the program into a `.ct` container.
1. `ct trace extract-gfx` extracts the graphics stream from the `.ct` container.
1. `ct gfx-replay` replays the extracted graphics stream and exposes frame, draw-call, pixel-history, and shader-debug APIs to the GUI.


When you open a compatible visual trace in CodeTracer, the GUI performs the extraction and player startup automatically. You usually only need to produce or open the `.ct` trace.

## Recording a visual trace

Use `ct record` with the interpose recording path. The `--use-interpose` flag routes through the MCR backend and captures graphics API calls:

```sh
ct record --use-interpose -o /tmp/demo.ct -- /path/to/program --args
```

For OpenGL tests in headless or CI environments, software rendering can make the result more reproducible:

```sh
LIBGL_ALWAYS_SOFTWARE=1 ct record --use-interpose -o /tmp/demo.ct -- /path/to/program
```

The output is a CTFS `.ct` file. It contains the native execution trace and the captured graphics events needed for visual replay. Keep this file as the artifact to share, import, or open later.

## Opening the trace in CodeTracer

Open the `.ct` file from the startup screen with **Open local trace**, or launch CodeTracer directly with a trace path:

```sh
ct host --trace-path=/tmp/demo.ct
```

For normal replay workflows, use the same GUI entry points you use for other traces. CodeTracer detects compatible MCR `.ct` files and marks the session as visual replay capable.

When the trace opens, CodeTracer extracts the graphics stream into a temporary directory and starts `ct gfx-replay --http`. The temporary extracted stream is an implementation detail; the `.ct` file remains the durable recording.

## GUI panels

Visual replay sessions add panels for graphics-specific debugging:

| Panel | Purpose |
| ----- | ------- |
| Frame Viewer | Shows rendered frames and the draw-call list for the selected frame. |
| Pixel History | Shows which draw calls modified the selected pixel and what color each modification wrote. |
| Shader Debugger | Shows shader source and per-invocation debugging information for a selected pixel or draw call. |

In the Frame Viewer, select a draw call to scrub the rendered frame to that draw. Click a pixel in the frame image to request pixel history. From a pixel-history entry, open shader debugging to inspect the shader source and recorded execution details for that pixel.

[![Frame Viewer showing a visual replay frame and draw-call list](../generated/visual_recordings/frame-viewer.png)](../generated/visual_recordings/frame-viewer.png)

The Frame Viewer is the starting point for visual debugging. It displays the replayed frame and the draw calls that contributed to it. Selecting a draw call scrubs the image to that point in the frame.

[![Pixel History panel showing recorded writes for a selected pixel](../generated/visual_recordings/pixel-history.png)](../generated/visual_recordings/pixel-history.png)

After clicking a pixel in the Frame Viewer, the Pixel History panel shows the draw calls that modified that pixel and the color written by each modification.

[![Shader Debugger panel showing shader source for a selected pixel](../generated/visual_recordings/shader-debugger.png)](../generated/visual_recordings/shader-debugger.png)

The Shader Debugger opens from a pixel-history selection and shows the shader source and recorded debugging information for the selected pixel or draw call.

Click any screenshot to open the generated full-size image.

## Manual extraction and player usage

The GUI normally manages this pipeline, but the lower-level commands are useful for diagnostics:

```sh
ct trace extract-gfx -o /tmp/demo-gfx /tmp/demo.ct
ct gfx-replay --gfx-stream /tmp/demo-gfx --http --port 9000
```

For offscreen or CI runs, force the software backend:

```sh
ct gfx-replay --backend software --gfx-stream /tmp/demo-gfx --http --port 9000
```

The HTTP player serves the same APIs used by the CodeTracer GUI, including frame loading, draw-call scrubbing, pixel history, and shader debugging.

## Development overrides

Development builds can point CodeTracer at non-default underlying binaries. The user-facing `ct trace extract-gfx` and `ct gfx-replay` subcommands resolve these binaries internally; the variables below override that resolution.

| Variable | Description |
| -------- | ----------- |
| `CODETRACER_CT_MCR_CMD` | Path to the internal MCR binary that `ct trace extract-gfx` invokes to read the graphics stream from a `.ct` container. |
| `CODETRACER_CT_GFX_PLAYER_CMD` | Path to the internal player binary that `ct gfx-replay` launches. |
| `CODETRACER_CT_GFX_PLAYER_BACKEND` | Optional player backend override (equivalent to passing `--backend` to `ct gfx-replay`), for example `software`. |

These variables are mainly useful when working from sibling development repositories. Installed builds should find the bundled tools without extra configuration.

## Regenerating the book screenshots

The screenshots on this page are generated by Playwright from a real visual recording:

```sh
just capture-docs-visual-screenshots
```

The command records the GL fixture from the sibling native test-programs repository when `CODETRACER_REAL_VISUAL_TRACE` is not set. To reuse an existing trace instead:

```sh
CODETRACER_REAL_VISUAL_TRACE=/path/to/demo.ct just capture-docs-visual-screenshots
```

The generated images are written to `docs/book/src/generated/visual_recordings/`. This directory is ignored by git, so screenshots can be regenerated for local review or release builds without checking binary image files into the repository.

To inspect the rendered book page layout after generating screenshots:

```sh
just capture-docs-visual-page
```

This regenerates the visual replay screenshots, builds the book, and writes an ignored page screenshot to `docs/book/src/generated/book_pages/visual-recordings-page.png`.

## Current limitations

Visual replay depends on the recorder being able to intercept the graphics API calls made by the target program. It is currently focused on native MCR traces with captured GL/VK activity. Programs that render through unsupported APIs or bypass the interposed path may still produce a regular native trace, but they will not expose the Frame Viewer, Pixel History, or Shader Debugger panels.
