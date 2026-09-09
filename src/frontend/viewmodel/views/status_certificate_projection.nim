## Projecting the certificate indicator's ViewModel onto what the status bar
## renders.
##
## A module of its own, between the two it joins, because the dependency has
## exactly one sensible direction and neither neighbour may take it: the VIEW
## (`isonim_status_view`) must not know about certificates, and the VIEWMODEL
## (`viewmodels/certificate_indicator_vm`) must not know about DOM records. So
## the projection sits above both and is imported by the wiring
## (`ui/certificate_indicator.nim`) and by the headless view suite.
##
## It reaches no host, which is the point: the question "what would a user see
## for this state" is answerable without a renderer, a DOM or a filesystem, on
## both Nim backends. That is what makes the four states assertable rather than
## merely screenshot-able.

import ./isonim_status_view
import ../viewmodels/certificate_indicator_vm

export isonim_status_view, certificate_indicator_vm

proc certificateTooltip*(model: CertificateIndicatorModel): string =
  ## What the indicator says on hover.
  ##
  ## THE HONESTY SENTENCE IS PART OF IT, not an extra. A tooltip that said
  ## "Certified" and stopped there would be the display implying a stronger
  ## guarantee than the certificate carries, which is the single thing
  ## Status-Bar.md's Notes single out — "valid" means *binds to the current
  ## state*, not *verified as unforgeable*. The remedy follows, so the hover
  ## also carries the difference between "run the tests" and "fix the
  ## configuration".
  result = model.summary
  if model.authenticityNote.len > 0:
    result.add " " & model.authenticityNote
  if model.remedy.len > 0:
    result.add " " & model.remedy

proc statusCertificateModel*(vm: CertificateIndicatorVm):
    StatusCertificateModel =
  ## Project the ViewModel onto the status bar's record.
  ##
  ## A `nil` ViewModel yields an EMPTY model, and the view renders an empty
  ## model as **no element at all**. That is what keeps this change invisible
  ## to every build and mode that has not wired an indicator — the same
  ## property `StatusBaseModel.buildLabel` relies on — rather than putting a
  ## placeholder in the footer of a product that has nothing to say.
  if vm.isNil:
    return StatusCertificateModel()
  let model = vm.model
  var rows: seq[StatusCertificateDetailRow] = @[]
  for row in model.detail:
    rows.add StatusCertificateDetailRow(label: row.label, value: row.value)
  StatusCertificateModel(
    label: model.label,
    stateClass: stateClass(model.state),
    title: certificateTooltip(model),
    disclosed: vm.disclosed,
    summary: model.summary,
    remedy: model.remedy,
    authenticityNote: model.authenticityNote,
    detail: rows)
