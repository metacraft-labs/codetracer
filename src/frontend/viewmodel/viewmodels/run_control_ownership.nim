## A declined click owns only the spinner it just added. Other editors may
## still be displaying a run that the host accepted earlier.
proc rollbackRunSpinner*[T](spinning: var seq[T]; editor: T;
                            wasSpinning: bool) =
  if wasSpinning:
    return
  let index = spinning.find(editor)
  if index >= 0:
    spinning.delete(index)
