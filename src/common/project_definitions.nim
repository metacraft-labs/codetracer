## project_definitions.nim — PLAT-11's package facade: how a repository
## teaches CodeTracer about itself, DECLARATIVELY, and nothing else.
##
## `import project_definitions` gives a caller the `.codetracer/` layout, the
## declarative grammar, the containment rule, the loader and the point
## re-resolver.
##
## ## WHAT IT GIVES A CALLER, AND WHAT IT CANNOT
##
## It gives no way to run anything. That is not a property of this facade, it
## is a property of everything under it: the package's whole import closure is
## `std/[algorithm, strutils, tables]` plus `common/toml_subset` and
## `common/value_presentation/vocabulary`, and `project_definitions_test`
## asserts that closure byte for byte. There is no `os`, no `osproc`, no
## `streams`, no `net`, no `dynlib`, no `times` — so "the declarative tier
## performs no I/O, no network, no process spawning and no filesystem access"
## (Project-Definitions.md §2.2) is a fact about what this code CAN reach,
## rather than a promise about what it chooses to do.
##
## The filesystem half is `src/ct/launch/project_definitions_dir.nim`, on the
## other side of the same line `plugin_model.nim`'s header draws between the
## pure plugin substrate and `src/ct/launch/plugin_components.nim`. It opens a
## CONSTANT set of file names and hands their bytes here.
##
## ## THIS IS NOT A PLUGIN, AND NOT A PLUGIN'S TRUST MODEL
##
## Extensibility-Model.md §1.0 and Project-Definitions.md §1.1 make the two
## different mechanisms on purpose: a plugin is installed once by a user who
## evaluated it, and a project definition arrives by `git clone` from someone
## the user has evaluated not at all. So this package shares nothing with
## `plugin_model`:
##
##   * no `Capability`, no `GrantSet`, no grant ledger, no capability
##     declaration — a declarative definition has no capabilities to grant
##     because it has no powers to grant it;
##   * no `PluginId` and no namespaced identity — a project definition is
##     scoped to the checkout it is in and has no identity outside it;
##   * a separate error type (`ProjectDefinitionProblem`) and a separate
##     diagnostics vocabulary, so a project definition's refusal can never be
##     rendered as "plugin '<unnamed>': …".
##
## Nothing here imports `plugin_model` and nothing in `plugin_model` imports
## this. The one type the two share is `PresentationKind`, which belongs to
## neither — it is PLAT-3's vocabulary, and sharing a *vocabulary* is the
## opposite of sharing a trust model.

import ./project_definitions/diagnostics
import ./project_definitions/containment
import ./project_definitions/layout
import ./project_definitions/model
import ./project_definitions/parse
import ./project_definitions/load
import ./project_definitions/resolve

export diagnostics, containment, layout, model, parse, load, resolve
