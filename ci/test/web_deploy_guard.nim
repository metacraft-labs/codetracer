## The guard on the bytes about to be uploaded.
##
## ## Why this is not a test
##
## Every gate in `ci/test/` grades a build. This grades a PUBLISH DIRECTORY,
## which is a different object and the one nothing in either repository could
## see. A sibling campaign proved the gap twice in one day:
##
##   * a replay engine was built, deployed and served at 18 MB while no page
##     referenced it, so every session was a still frame and the symptom read
##     as "the engine is stale" for hours;
##   * the mirror failure, a page referencing an engine nobody had published,
##     produced a 404 that read as the same sentence.
##
## Both are invisible to a build gate and to a rendered-markup gate, because
## each is a property of the MARKUP AND THE FILE TREE TOGETHER. That property
## only exists at the moment of publishing, so the check lives here and runs
## there.
##
## ## It fails in both directions, deliberately
##
## `deployGuardDefects` in `platform/web_deployment.nim` is the rule, and it is
## a value in the product rather than a grep in a script for the reason that
## module's header gives about every other list it owns. This program supplies
## the two inputs the rule needs — what the entry document DECLARES and what the
## directory CONTAINS — and prints what it says.
##
## A guard that only failed one way would have been green on one of the two
## failures above. Which one depends on which mistake somebody made that day,
## which is not a property worth betting a production deploy on.
##
## Usage:  web_deploy_guard <publish-dir>
## Exit:   0 clean, 1 defects found, 2 could not run

import std/[os, strutils]

import ../../src/frontend/viewmodel/platform/web_deployment

proc descriptorTextFrom(document: string): string =
  ## The descriptor JSON, extracted from the served HTML exactly as a browser
  ## would find it: the text content of the element with the agreed id.
  ##
  ## Parsed out of the DOCUMENT rather than re-rendered from the manifest, and
  ## that is the entire point. Re-rendering would compare the product with
  ## itself and pass over any publish directory whatsoever — the empty-set pass
  ## this repository keeps finding. What is graded here is the file that will
  ## be served.
  let idMarker = "id=\"" & deploymentDescriptorElementId & "\""
  let idAt = document.find(idMarker)
  if idAt < 0: return ""
  let openEnd = document.find('>', idAt)
  if openEnd < 0: return ""
  let closeAt = document.find("</script>", openEnd)
  if closeAt < 0: return ""
  document[openEnd + 1 ..< closeAt]

proc servedPaths(publishDir: string): seq[string] =
  ## Every file in the directory, as the root-relative URL it will be served at.
  for path in walkDirRec(publishDir, relative = true):
    result.add "/" & path.replace('\\', '/')

proc scriptReferences(document: string): seq[string] =
  ## Same-origin absolute `src`s only.
  ##
  ## A cross-origin script is somebody else's to serve and a relative one is
  ## resolved by the page's own directory, which is not a claim about this
  ## tree's layout. Same rule as the sibling's deploy workflow, and the same
  ## reason.
  var i = 0
  while true:
    let at = document.find("<script", i)
    if at < 0: break
    let tagEnd = document.find('>', at)
    if tagEnd < 0: break
    let tag = document[at .. tagEnd]
    let srcAt = tag.find("src=\"/")
    if srcAt >= 0:
      let valueStart = srcAt + len("src=\"")
      let valueEnd = tag.find('"', valueStart)
      if valueEnd > valueStart:
        var reference = tag[valueStart ..< valueEnd]
        # Strip any ?query / #fragment before touching the file tree.
        for cut in ['?', '#']:
          let at2 = reference.find(cut)
          if at2 >= 0: reference = reference[0 ..< at2]
        result.add reference
    i = tagEnd + 1

when isMainModule:
  if paramCount() < 1:
    stderr.writeLine "usage: web_deploy_guard <publish-dir>"
    quit 2
  let publishDir = paramStr(1)
  if not dirExists(publishDir):
    stderr.writeLine "no such publish directory: " & publishDir
    quit 2

  var defects: seq[string]
  var checks = 0

  let documentPath = publishDir / entryDocumentPath
  if not fileExists(documentPath):
    stderr.writeLine "the publish directory has no " & entryDocumentPath &
      ", so every rewrite in _redirects would 404"
    quit 1
  let document = readFile(documentPath)
  let served = servedPaths(publishDir)

  # ---------------------------------------------------------------------
  # NON-VACUITY FIRST. Every check below is satisfied by an empty directory
  # and an empty document, which is the shape this repository keeps finding:
  # "found nothing wrong" meaning "looked at nothing".
  # ---------------------------------------------------------------------
  if served.len < 3:
    stderr.writeLine "the publish directory holds only " & $served.len &
      " file(s); every check below would be vacuous"
    quit 1
  echo "publish directory: " & $served.len & " file(s)"

  # 1. Every REQUIRED runtime asset is present and not truncated.
  #
  # THE ENTRY DOCUMENT IS SIZED DIFFERENTLY, and finding out why is what this
  # guard's own mutation testing was for. The 1 KB floor is right for the two
  # bundles and the worker — the renderer is 13 MB, so 1 KB is far below any
  # real value and far above an empty file. Applied to the document it is a
  # FALSE POSITIVE waiting to happen: a correct deployment that ships no wasm
  # modules renders a 986-byte document, and the rule would have rejected it as
  # truncated. That is the worst kind of guard — one that fails on a state the
  # product supports and documents (`required: false` on both modules, each
  # with an `absenceBehaviour` sentence), so the first person to meet it
  # deletes the check.
  #
  # A document is graded on whether it can do its job instead, which is the
  # property actually at stake and is checked below in full: it must carry a
  # descriptor and it must reference its bundles. Size tells us nothing here
  # that those two do not tell us better.
  #
  # AND IT IS LOOKED UP BY STEM, NOT BY EQUALITY. Everything under `/assets/`
  # is published as `<name>.<digest>.<ext>`, so `publishDir / asset.path` names
  # a file no deployment contains: this loop would have reported the worker
  # script — a REQUIRED asset — missing from every correct bundle. The published
  # set is searched for a file whose `contentAddressedStem` is the manifest
  # path, which is the same question asked in the direction the rename goes.
  proc publishedFor(manifestPath: string): string =
    ## The served path this manifest row was published at, or "".
    let stem = "/" & manifestPath
    for candidate in served:
      if candidate == stem or contentAddressedStem(candidate) == stem:
        return candidate
    ""

  for asset in webRuntimeAssets():
    if not asset.required: continue
    inc checks
    let publishedAt = publishedFor(asset.path)
    let path = publishDir / publishedAt.strip(chars = {'/'}, trailing = false)
    let floor = if asset.mode == damEntryDocument: 0 else: 1024
    if publishedAt.len == 0 or not fileExists(path):
      defects.add "required asset `" & asset.id & "` is missing from the " &
        "publish directory at " & asset.path &
        " (searched for it under a content-addressed name too)"
    elif getFileSize(path) <= floor:
      defects.add "required asset `" & asset.id & "` is only " &
        $getFileSize(path) & " bytes at " & publishedAt & " — truncated or empty"
    else:
      echo "  ok: " & asset.id & " -> " & publishedAt & " (" &
        $getFileSize(path) & " bytes)"

  # 2. The declaration and the directory agree, both ways.
  let descriptorText = descriptorTextFrom(document)
  if descriptorText.strip().len == 0:
    defects.add "the entry document carries no `" &
      deploymentDescriptorElementId & "` descriptor, so the page cannot " &
      "know what this deployment delivered and would report no toolchain " &
      "however many modules were uploaded"
  else:
    let descriptor = parseDeploymentDescriptor(descriptorText)
    echo "  the document declares " & $descriptor.modules.len &
      " wasm module(s), revision " &
      (if descriptor.revision.len > 0: descriptor.revision else: "(unset)")
    for module in descriptor.modules:
      inc checks
      echo "    " & module.id & " -> " & module.url & " (" & $module.bytes &
        " bytes declared) " & module.builtFrom
    for defect in deployGuardDefects(descriptor, served):
      defects.add defect
    # THE SIZE IS COMPARED, not trusted. A declaration that says 16 MB over a
    # file of 400 bytes is the "green build that served a cached store path"
    # failure, and it is caught here rather than in a visitor's console.
    for asset in descriptor.assets:
      inc checks
      echo "    " & asset.id & " -> " & asset.url & " (" & $asset.bytes &
        " bytes declared)"
    for module in descriptor.modules:
      let path = publishDir / module.url.strip(chars = {'/'}, trailing = false)
      if not fileExists(path): continue
      inc checks
      let actual = getFileSize(path).int
      if actual != module.bytes:
        defects.add "the entry document declares `" & module.id & "` at " &
          $module.bytes & " bytes and the publish directory holds " &
          $actual & " — the document and the bytes are from different builds"
    for asset in descriptor.assets:
      let path = publishDir / asset.url.strip(chars = {'/'}, trailing = false)
      if not fileExists(path): continue
      inc checks
      let actual = getFileSize(path).int
      if actual != asset.bytes:
        defects.add "the entry document declares `" & asset.id & "` at " &
          $asset.bytes & " bytes and the publish directory holds " &
          $actual & " — the document and the bytes are from different builds"

    # THE CACHE CLASS THE PUBLISHED SET EARNED, stated where the bytes are.
    #
    # Counted and named, not merely derived: `staticAssetGlobClass` answers
    # `ccMutableAsset` for a set with one stable name in it AND for a set with
    # no names in it at all, and those are two very different deployments. The
    # count is what tells them apart, and `deployGuardDefects` is what names the
    # offending file in the first case.
    let publishedAssets = publishedStaticAssets(descriptor)
    inc checks
    if publishedAssets.len == 0:
      defects.add "the entry document declares no /assets/ file at all — the " &
        "cache table would be derived from an empty set, and a universal " &
        "claim about nothing is not evidence for `immutable`"
    else:
      echo "  ok: " & $publishedAssets.len & " published /assets/ file(s), " &
        "of which " & $unhashedStaticAssets(descriptor).len &
        " carry no digest; /assets/* -> " &
        headerFor(staticAssetGlobClass(descriptor))

  # 3. Every same-origin script the document asks for was published.
  let references = scriptReferences(document)
  if references.len == 0:
    defects.add "the entry document carries no same-origin <script> — a page " &
      "that can never boot"
  for reference in references:
    inc checks
    let path = publishDir / reference.strip(chars = {'/'}, trailing = false)
    if not fileExists(path) or getFileSize(path) <= 0:
      defects.add "the entry document references " & reference &
        " and the publish directory does not contain it"
    else:
      echo "  ok: document references " & reference & " (" &
        $getFileSize(path) & " bytes)"

  echo ""
  if checks == 0:
    stderr.writeLine "RESULT: FAILED — the guard asserted nothing at all"
    quit 1
  if defects.len == 0:
    echo "RESULT: OK — " & $checks & " check(s); the document and the " &
      "published files agree"
    quit 0
  for defect in defects:
    stderr.writeLine "  * " & defect
  stderr.writeLine "RESULT: FAILED — " & $defects.len &
    " defect(s) in what was about to be published"
  quit 1
