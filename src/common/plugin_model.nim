## plugin_model.nim — PLAT-7's package facade for the PURE half of the plugin
## substrate: identity, manifest, resolution and activation planning.
##
## `import plugin_model` gives a caller the manifest types, the load-time
## validation, the DAG resolver and the activation planner. It gives a caller
## NOTHING reactive: this package imports `std/[json, strutils, tables, sets,
## algorithm]` and `common/view_vocabulary`, and nothing else — no `isonim`,
## no ViewModel, no clock, no filesystem, no process.
##
## THE SPLIT IS THE SAME ONE `view_vocabulary.nim` MAKES, for the same reason.
## Everything a plugin system decides before anything runs is decidable
## without a runtime, so it is decided here and exercised by a unit lane that
## links no renderer. What genuinely needs the reactive core — the activation
## scope, the effect budget, deactivation through the owner tree — lives in
## `src/frontend/viewmodel/plugin_host/`, on the other side of this line.
##
## A reader looking for "where does a plugin's effect actually run" is in the
## wrong file, and that is the intended answer rather than an omission.

import ./plugin_model/diagnostics
import ./plugin_model/manifest
import ./plugin_model/resolution
import ./plugin_model/activation

export diagnostics, manifest, resolution, activation
