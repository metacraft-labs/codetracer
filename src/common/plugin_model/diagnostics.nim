## plugin_model/diagnostics.nim — PLAT-7. The one error type, and the rule
## that every instance of it names the plugin.
##
## ## WHY THIS IS A TYPE AND NOT A STRING
##
## Extensibility-Model.md §4.1: "A manifest naming something that does not
## exist is a **load-time error naming the extension**, never a silently
## missing feature." A `string` satisfies that sentence only as long as every
## call site remembers to interpolate the id, and the failure mode of
## forgetting is exactly the one the sentence forbids — an error that says
## "unknown view kind" and leaves the reader to guess which of forty installed
## plugins wrote it.
##
## So `plugin` is a FIELD, not a formatting convention. `render` puts it first
## and `plugin_model_test` sweeps every error the whole suite constructs and
## asserts the id is present in the rendered text — a sweep rather than a
## per-case claim, because a per-case claim is satisfied by the cases somebody
## remembered to write.
##
## ## THE CODE IS SEPARATE FROM THE DETAIL
##
## `code` is what a caller may branch on; `detail` is what a reader needs.
## `Verification-Harness-Traps` §4b's lesson applies to refusals as much as to
## scans: a test asserting only "it refused" passes when the refusal was for
## the wrong reason, so every refusal in the suite is asserted by `code`.

import std/strutils

type
  PluginErrorCode* = enum
    ## Why a plugin could not be loaded. Ordered roughly by the phase that
    ## discovers it: parse, then per-manifest validation, then registry-wide
    ## resolution.
    pecMalformedManifest    ## not an object, or not JSON at all
    pecMissingField         ## a required key is absent
    pecBadVersion           ## a version string is not `major.minor.patch`
    pecBadVersionRange      ## a requirement range could not be read
    pecUnknownCapability    ## §8.1.2 names six; this is not one of them
    pecUnknownContribution  ## §6.1 names four surfaces; this is not one
    pecUnknownView          ## a contributed surface names a view PLAT-3's
                            ## vocabulary does not contain
    pecUnknownActivation    ## an activation event outside the declared set
    pecEagerWithoutReason   ## §4.2: eager activation must say why
    pecActivationValueMissing ## `language`/`command`/`pane` need an argument
    pecDuplicatePlugin      ## two manifests claim one id
    pecMissingDependency    ## a dependency id no manifest declares
    pecVersionConflict      ## a dependency exists at an unacceptable version
    pecDependencyCycle      ## §4.2: "a cycle is an error naming the cycle"
    pecBlockedByDependency  ## §4.2: "does not activate half-alive"
    pecCoreTooOld           ## the host does not satisfy `requires.core`
    pecUnknownCommand       ## activation on a command nobody contributes
    pecCapabilityWithoutDeclaration
      ## PLAT-8. §8.1.1: the host resolves an executable "against a declared
      ## set", and §8.1.2 grants `socket:remote` "to declared hosts". A grant
      ## whose declared set is empty is a grant that permits nothing, and an
      ## author who wrote it meant something else.
    pecDeclarationWithoutCapability
      ## The mirror. A manifest declaring executables it was not granted
      ## `process` for reads, to a user, as though it could spawn them.
    pecBadDeclaration
      ## A declared executable that is a path rather than a name, a declared
      ## host with an unusable port, a declared path that is not absolute.
    pecTraceEgressNotAcknowledged
      ## A capability composition that can move recorded data off the machine,
      ## without the explicit, informed grant. PLAT-8's verification gate.
      ##
      ## TWO COMPOSITIONS TRIGGER IT, not one. §8.1.2's pair — `trace` +
      ## `socket:remote` — and `process` on its own, because `process`
      ## subsumes every other capability (`capabilities.SubsumingCapabilities`).
      ## The second was added on 2026-09-09 after a plugin holding `trace`,
      ## `fs:read` and `process` — no socket capability, no declared host —
      ## exfiltrated a recording with this error never raised.
    pecTraceEgressWithoutPair
      ## The grant present without any such composition. A user was asked to
      ## acknowledge an exfiltration path the plugin cannot take, which trains
      ## them to acknowledge the next one without reading it.

    # -- PLAT-9. §6's surfaces, §6.3's required/optional rule, and §8.2's
    # -- dependency declarations. Every one of them is a LOAD-TIME refusal for
    # -- §4.1's reason: a surface that quietly does nothing is the blank tab.
    pecUnknownFrontEnd
      ## A `nativeViews` entry naming a front-end PLAT-3's vocabulary does not
      ## have. The three are `terminal`, `web` and `gpui`, with the `--ui`
      ## spellings accepted as aliases.
    pecUnknownRequirement
      ## §6.3 has exactly two: `required` and `optional`. A third spelling is
      ## refused rather than rounded to one of them, because rounding it down
      ## produces a surface that silently does nothing and rounding it up
      ## refuses a plugin the author meant to ship.
    pecBadContributedPaneId
      ## §6.1/§10.2's namespaced string, against `contributed_pane_id`'s
      ## grammar. The id is persisted into a layout the desktop reads back, so
      ## it is validated where it enters rather than where it is rendered.
    pecUndeclaredDependency
      ## §8.2: a surface names a dependency in `needs` that the manifest's
      ## `executables` does not declare. The host resolves a tool against the
      ## declared set (§8.1.1), so a need outside it can never be satisfied —
      ## which is a permanently degraded surface nobody wrote down.
    pecMissingInstallHint
      ## §8.2: "The degradation says **what is missing and how to get it** — a
      ## name and an install action, not 'unavailable'." A surface declaring a
      ## dependency without the remedy could only ever render 'unavailable',
      ## so the remedy is required at load time rather than hoped for.
    pecSurfaceUnavailableOnFrontEnd
      ## §6.3's rule, at resolution time: a REQUIRED surface with no view for
      ## the active front-end. The detail names the front-end AND the surface,
      ## because "an extension that appears to load and then silently does
      ## nothing" is what §6.3 exists to prevent.
    pecUnknownReprobeTrigger
      ## §8.2's "re-probed on a declared trigger". The trigger vocabulary is
      ## §4.2's activation events — one vocabulary, not two — so an unknown
      ## trigger fails the same way an unknown activation event does.
    pecDuplicateContribution
      ## §6.1. TWO RENDERING SURFACES OF ONE MANIFEST SHARING A LOCAL ID.
      ##
      ## The qualified id is `<plugin>/<surface>` and carries no contribution
      ## kind, so a `pane` and a `marker` both called `metrics` compose the
      ## same string — one registry key, one `declaresSurface` answer, one
      ## `contributeView` target. Measured before the rule existed: the
      ## manifest parsed with zero errors, the host registered one record, and
      ## the second contribution was dropped by a `hasKey` test with nothing
      ## anywhere saying it had gone. That is `lpUnknownPane`'s
      ## silently-missing-surface failure arriving at load time instead of at
      ## restore time, which is the one thing §6.1 exists to prevent.
      ##
      ## The refusal names BOTH contributions, because either may be the typo
      ## and an author told only "duplicate id" has to find the other one.

    # -- PLAT-10. §8.3's distribution: a plugin is a COMPONENT, installed by
    # -- `ct install` into `<root>/<name>@<version>`. These four are what can
    # -- go wrong between "a directory exists" and "a manifest was read", and
    # -- every one of them is reported for §4.1's reason — a plugin that
    # -- silently is not there is the blank tab in its largest form.
    pecPluginAlsoDispatchable
      ## §8.3's first distinction: "**A plugin is not a front-end.** Components
      ## today are things the launcher `exec`s into by command word. A plugin
      ## is loaded by a running CodeTracer. Sharing the *distribution* format
      ## must not imply sharing the dispatch model."
      ##
      ## A component directory carrying BOTH `plugin.json` and `capabilities`
      ## claims both, so it is refused as a plugin and the refusal names both
      ## files. Without this the rule would be a convention held by whoever
      ## built the tarball.
    pecPluginIdComponentMismatch
      ## The `id` in `plugin.json` is not the component name it was installed
      ## as. §4.1 makes the id the identity and §8.3 makes the component name
      ## what `ct install`, `ct uninstall` and a `.ctrc` pin all spell, so two
      ## different strings would mean a user could not pin, upgrade or remove
      ## the plugin they were reading about.
    pecBadComponentDirectory
      ## A directory under a components root that carries a plugin manifest and
      ## whose name is not `<name>@<version>`. Reported rather than skipped,
      ## because a plugin that was installed by hand into a misnamed directory
      ## is invisible to `ct uninstall` as well as to this.
    pecPinnedVersionMissing
      ## `.ctrc` pins a version of an installed plugin that is not present.
      ## The launcher `continue`s past every other version in that case, so the
      ## plugin does not load — and a user who checked a pin into their
      ## repository is owed the sentence rather than an absence.

  PluginError* = object
    plugin*: PluginId
      ## ALWAYS set. See the header.
    code*: PluginErrorCode
    detail*: string
      ## The specifics a reader needs: which view, which dependency, which
      ## cycle. Never a restatement of `code`.

  PluginId* = string
    ## A plugin's stable identity. Namespaced by convention (`publisher.name`)
    ## and validated as such by `manifest.validateId`, because §10's open
    ## decision 2 recommends "a namespaced string for contributed ones" and an
    ## id that is not namespaced cannot be one.

func codeText*(c: PluginErrorCode): string =
  ## The human half of the code. Written here rather than at each raise site
  ## so one code cannot acquire two spellings.
  case c
  of pecMalformedManifest: "malformed manifest"
  of pecMissingField: "missing required field"
  of pecBadVersion: "malformed version"
  of pecBadVersionRange: "malformed version range"
  of pecUnknownCapability: "unknown capability"
  of pecUnknownContribution: "unknown contribution kind"
  of pecUnknownView: "unknown view"
  of pecUnknownActivation: "unknown activation event"
  of pecEagerWithoutReason: "eager activation without a stated reason"
  of pecActivationValueMissing: "activation event without its argument"
  of pecDuplicatePlugin: "duplicate plugin id"
  of pecMissingDependency: "missing dependency"
  of pecVersionConflict: "dependency version conflict"
  of pecDependencyCycle: "dependency cycle"
  of pecBlockedByDependency: "blocked by a failed dependency"
  of pecCoreTooOld: "core version requirement not met"
  of pecUnknownCommand: "activation names a command nobody contributes"
  of pecCapabilityWithoutDeclaration: "capability granted with nothing declared"
  of pecDeclarationWithoutCapability: "declaration without the capability it needs"
  of pecBadDeclaration: "malformed declaration"
  of pecTraceEgressNotAcknowledged:
    # NOT "'trace' + 'socket:remote'" any more. That spelling was the whole
    # trigger until 2026-09-09 and it is now one of two: `process` subsumes
    # every other capability, so it needs the same grant on its own, and a
    # code text naming a composition the plugin does not hold is a wrong
    # answer printed above a right one. The DETAIL is the disclosure and says
    # which composition fired.
    "an exfiltration path without the explicit trace-egress grant"
  of pecTraceEgressWithoutPair:
    "a trace-egress grant on a plugin that has no exfiltration path"
  of pecUnknownFrontEnd: "unknown front-end"
  of pecUnknownRequirement: "unknown surface requirement"
  of pecBadContributedPaneId: "malformed contributed pane id"
  of pecUndeclaredDependency: "surface needs a tool the manifest never declared"
  of pecMissingInstallHint: "a declared dependency with no way to get it"
  of pecSurfaceUnavailableOnFrontEnd:
    "a required surface has no view for this front-end"
  of pecUnknownReprobeTrigger: "unknown re-probe trigger"
  of pecDuplicateContribution:
    "two rendering surfaces share one local id"
  of pecPluginAlsoDispatchable:
    "a plugin component that also claims the launcher's command dispatch"
  of pecPluginIdComponentMismatch:
    "the plugin id is not the component name it was installed as"
  of pecBadComponentDirectory:
    "a plugin outside the '<name>@<version>' component layout"
  of pecPinnedVersionMissing:
    "a .ctrc pin names a version that is not installed"

func pluginError*(plugin: PluginId; code: PluginErrorCode;
                  detail: string): PluginError =
  PluginError(plugin: plugin, code: code, detail: detail)

func render*(e: PluginError): string =
  ## THE PLUGIN COMES FIRST. A reader scanning a column of these must be able
  ## to attribute every line without reading to the end of it.
  "plugin '" & e.plugin & "': " & codeText(e.code) &
    (if e.detail.len > 0: ": " & e.detail else: "")

func renderAll*(errors: seq[PluginError]): string =
  var lines: seq[string] = @[]
  for e in errors:
    lines.add render(e)
  lines.join("\n")

func namesPlugin*(e: PluginError): bool =
  ## The property the suite sweeps for. It is a function rather than an
  ## assertion inside the test so that the *rule* and its *control* are one
  ## piece of code: `plugin_model_test` proves it can answer `false` by
  ## handing it an error whose `plugin` was left empty.
  e.plugin.len > 0 and render(e).contains(e.plugin)
