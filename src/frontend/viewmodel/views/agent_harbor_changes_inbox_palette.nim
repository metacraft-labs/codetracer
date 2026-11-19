## views/agent_harbor_changes_inbox_palette.nim
##
## The colours the Changes panel and the Inbox are drawn in by the native
## front-ends, resolved from the design system's roles in either colour mode.
##
## The web views name a state by a role (`agent_harbor_changes_inbox_words`:
## `warning`, `success`, `error`, `info`, `quiet`, `idle`) and their
## stylesheets (`styles/components/agent_harbor_changes.styl`,
## `agent_harbor_inbox.styl`) give each role its ink: the word in the role's
## text colour, its dot in the role's icon colour. A native view has no
## stylesheet, so this module resolves the same roles from the same
## generated tokens (`styles/generated/design_tokens.nim`), beside the Agent
## Harbor palette every native view already shares (`agent_harbor_palette`).
## It also holds the few roles those two stylesheets use that the shared
## palette does not: the information ink, the input surface, the disabled
## control, the VCS row's status letters.
##
## It renders nothing and imports no renderer, so the GPUI and terminal
## views of the same viewmodels resolve each role alike, as they do the
## shared palette's.

import ../../styles/generated/design_tokens
import ./agent_harbor_palette

export agent_harbor_palette

type
  ChangesInboxInks* = object
    ## The extra roles of the two stylesheets, in one colour mode.
    textInfo*: string            ## text/information/primary: a hunk header, a file link
    borderInfo*: string          ## border/information: a draft's inset bar
    inputSurface*: string        ## surface/input/secondary: a text field
    placeholder*: string         ## text/primary/label-subtle: a field's placeholder
    disabledSurface*: string     ## surface/primary/disabled: a disabled field
    borderDisabled*: string      ## border/disabled: a disabled step or field
    actionHover*: string         ## surface/action/primary-hover
    vcsAdded*: string            ## `.vcs-status-added`, `.vcs-stat-added`
    vcsDeleted*: string          ## `.vcs-status-deleted`, `.vcs-stat-deleted`
    vcsModified*: string         ## `.vcs-status-modified`
    vcsOther*: string            ## `.vcs-status-other` (a rename's `R` among them)

proc changesInboxInks*(mode: DesignMode): ChangesInboxInks =
  template t(token: DesignToken): string = DesignTokenHex[token][mode]
  ChangesInboxInks(
    textInfo: t(dtColorsUiTextInformationPrimary),
    borderInfo: t(dtColorsUiBorderInformation),
    inputSurface: t(dtColorsUiSurfaceInputSecondary),
    placeholder: t(dtColorsUiTextPrimaryLabelSubtle),
    disabledSurface: t(dtColorsUiSurfacePrimaryDisabled),
    borderDisabled: t(dtColorsUiBorderDisabled),
    actionHover: t(dtColorsUiSurfaceActionPrimaryHover),
    # vcs.styl's own literals for Dark, where it states one (`by-mode` with a
    # hex: "The status letters were written for the dark ground"); the light
    # theme takes each status's text role. Deleted and other are literals in
    # both modes.
    vcsAdded: (if mode == dmDark: "#4ec9b0" else: t(dtColorsUiTextSuccessPrimary)),
    vcsDeleted: "#f44747",
    vcsModified: (if mode == dmDark: "#e5c07b" else: t(dtColorsUiTextWarningPrimary)),
    vcsOther: "#888888")

proc roleInk*(p: AhPalette; ink: ChangesInboxInks; role: string): string =
  ## A role's word colour (`.ah-role-<role>`'s `color`): the role's text
  ## colour; `quiet`, `idle` and no role the caption colour.
  case role
  of "warning": p.textWarning
  of "success": p.textSuccess
  of "error": p.textError
  of "info": ink.textInfo
  else: p.textCaption

proc roleDot*(p: AhPalette; role: string): MarkStyle =
  ## A role's dot (`.ah-role-<role>`'s `--ah-role-ink`): the role's icon
  ## colour; `idle` a hollow ring and `quiet` a dot in the quiet icon role
  ## (`by-mode(icon/primary/subtle, icon/primary/default-hover)`, the shared
  ## palette's ended mark).
  case role
  of "warning": MarkStyle(colour: p.iconWarning)
  of "success": MarkStyle(colour: p.iconSuccess)
  of "error": MarkStyle(colour: p.iconError)
  of "info": MarkStyle(colour: p.iconInfo)
  of "idle": MarkStyle(colour: p.endedMark, ring: true)
  else: MarkStyle(colour: p.endedMark)

proc vcsStatusInk*(ink: ChangesInboxInks; status: string): string =
  ## A VCS row's status letter (`isonim_vcs_view.statusClass`): added and
  ## untracked green, deleted red, modified amber, any other grey.
  case status
  of "?", "untracked", "A", "added": ink.vcsAdded
  of "D", "deleted": ink.vcsDeleted
  of "M", "modified": ink.vcsModified
  else: ink.vcsOther
