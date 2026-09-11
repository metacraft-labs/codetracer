## tool_surface_plugin.nim — PLAT-9's §8.2 fixture: a plugin with two panes,
## one of which needs an external program and one of which does not.
##
## §8.2: "A plugin declares, per surface, which of its dependencies that
## surface needs. A missing one degrades **that surface**, not the whole
## plugin, and not the application." The two surfaces here are what makes that
## sentence checkable: `disassembly` needs a tool, `notes` needs nothing, and
## the milestone's second integration test asserts that the first is visibly
## degraded WHILE the second renders its real content.
##
## ## THE TOOL NAME IS DELIBERATELY ONE NOTHING SHIPS
##
## `ct-plat9-probe-tool` is not a program anybody has. The suite creates one in
## a temporary directory, puts that directory on `PATH`, and fires the declared
## re-probe trigger — so "installing the missing component does not require
## restarting CodeTracer" is exercised against a real executable appearing on a
## real PATH, resolved by PLAT-8's own `resolveExecutable`.
##
## ## WHY IT HOLDS `process`, AND WHY THAT DRAGS IN THE EGRESS GRANT
##
## §8.1.1 has the host resolve a tool name "against a declared set", so a
## surface's `needs` must be in `executables` — and `executables` without the
## `process` capability is `pecDeclarationWithoutCapability`. PLAT-8's repair of
## 2026-09-09 then makes `process` an exfiltration path on its own (it subsumes
## every other capability), so the manifest carries the trace-egress
## acknowledgement. That chain is not incidental to this fixture: it is what a
## real plugin declaring a tool dependency will have to write, and a fixture
## that dodged it would be testing a manifest nobody can ship.

import codetracer_plugin

const ManifestJson* = """
{
  "id": "acme.disasm",
  "displayName": "Disassembly",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "capabilities": ["process"],
  "executables": ["ct-plat9-probe-tool"],
  "traceEgress": {
    "acknowledged": true,
    "statement": "this plugin runs a local disassembler over recorded code bytes and keeps the output on this machine"
  },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "disassembly",
        "title": "Disassembly",
        "requirement": "optional",
        "views": ["Table", "Text"],
        "needs": ["ct-plat9-probe-tool"],
        "install": "ct install ct-plat9-probe-tool",
        "reprobe": [ { "event": "trace-opened" } ] },
      { "id": "notes",
        "title": "Notes",
        "requirement": "optional",
        "views": ["Text"] }
    ]
  }
}
"""

const NoReprobeManifestJson* = """
{
  "id": "acme.disasm-static",
  "displayName": "Disassembly, without a re-probe trigger",
  "version": "1.0.0",
  "requires": { "core": ">=1.0.0 <2.0.0" },
  "capabilities": ["process"],
  "executables": ["ct-plat9-probe-tool"],
  "traceEgress": {
    "acknowledged": true,
    "statement": "this plugin runs a local disassembler over recorded code bytes and keeps the output on this machine"
  },
  "activation": [
    { "event": "trace-opened" }
  ],
  "contributes": {
    "pane": [
      { "id": "disassembly",
        "title": "Disassembly",
        "requirement": "optional",
        "views": ["Text"],
        "needs": ["ct-plat9-probe-tool"],
        "install": "ct install ct-plat9-probe-tool" }
    ]
  }
}
"""
  ## THE CONTROL FOR THE TRIGGER. The same surface with no `reprobe` array, so
  ## the same event leaves it alone. Without this twin, "the trigger re-probed
  ## it" and "any event re-probes everything" are the same observation.

const NotesText* = "three notes, and the tool has nothing to do with them"

type
  ToolSurfacePlugin* = ref object
    activations*: int
    disassemblyRenders*: int
      ## Incremented INSIDE the degradable surface's view. §8.2's "A pane that
      ## renders as though it were complete while a dependency is absent is
      ## the plugin-model version of a green suite that asserts nothing" is
      ## asserted by this staying at zero while the tool is missing — the
      ## boundary must not even call the view, not merely discard its output.
    notesRenders*: int

proc newToolSurfacePlugin*(): ToolSurfacePlugin = ToolSurfacePlugin()

proc activator*(p: ToolSurfacePlugin): proc(ctx: PluginContext) =
  result = proc(ctx: PluginContext) =
    inc p.activations
    ctx.contributeView("disassembly", proc(): ViewNode =
      inc p.disassemblyRenders
      viewTable("acme.disasm.rows", @["address", "mnemonic"],
                @[@["0x1000", "push rbp"], @["0x1001", "mov rbp, rsp"]]))
    if ctx.manifest.declaresSurface("notes"):
      ctx.contributeView("notes", proc(): ViewNode =
        inc p.notesRenders
        viewText("acme.disasm.notes", NotesText))
