include common_lang

proc getExtension*(lang: Lang): string =
  ## The native-backend spelling.  The table itself is the exhaustive ``case``
  ## ``getExtensionName`` in ``common_lang.nim``, shared with the JS front end
  ## so the two cannot drift.
  getExtensionName(lang)

proc toLangFromFilename*(location: string): Lang =
  try:
    let extensionWithDot = location.splitFile()[2]
    if extensionWithDot.len > 0:
      let extension = extensionWithDot[1..^1]
      # echo location, " ", extensionWithDot
      result = toLang(extension)
    else:
      result = LangUnknown
  except:
    result = LangUnknown
