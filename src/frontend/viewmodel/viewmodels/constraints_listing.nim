## viewmodels/constraints_listing.nim — a circuit's opcodes, and the source line
## each one came from.
##
## A measurement of a Noir project yields three artefacts, and this module is
## what joins them (`Noir-Studio.md` § 9.2.1, "Every row carries its link to
## source"):
##
##   * `nargo info --json` names the functions and says how many opcodes each
##     has;
##   * `--print-acir` on the same command prints the opcodes themselves, on the
##     same standard output, ahead of the JSON;
##   * the program the command leaves at `target/<package>.json` says where each
##     opcode came from: `debug_symbols` is base64 of raw deflate of JSON, which
##     maps an opcode's index to a call stack, and `file_map` holds the files
##     the stacks' spans are byte offsets into.
##
## Every host reaches the same answer through these procs: the terminal's and
## the GPUI window's host (`host/native_constraints_host`) and the desktop's
## renderer (`ui_js.onNs9PanesConstraints`, from what `index/ns9_panes` read).
## Pure; C and JavaScript backends.
##
## ## How a listing is matched to the report, and why it can be refused
##
## The artefact's own function order is the listing's: the k-th `func` block is
## the k-th entry of `nargo info`'s `functions` and of `debug_infos`, and an
## `unconstrained func N` block is the `unconstrained_functions` entry at N and
## the `brillig_locations` key N (measured on nargo 1.0.0-beta.26, with `#[fold]`
## functions and with several Brillig functions). So a function keeps the NAME
## `nargo info` gave it and takes its ROWS by position — and each function's row
## count has to equal the total `nargo info` printed, because a total and the
## listing under it must not describe the circuit differently (§ 9.2). When they
## disagree, or when a workspace prints one listing per package and the report
## reads only the first package, the listing is REFUSED: the totals stand, and
## the pane says why the rows are not shown (`listingAbsence`).
##
## ## Which line an opcode leads to
##
## A press opens ONE line, so unlike the generated-code listing's anchors
## (`noir_anchor_producer`, which keeps every frame of an inlined opcode as a
## merged mapping) this has to choose. It chooses the INNERMOST FRAME IN THE
## PROJECT'S OWN SOURCES: Noir inlines `checks::in_range` into `main`, and the
## opcode's cost is written where the body of `in_range` says so, not at the call
## (GCL-D1 orders the frames for the same reason). Frames in the standard library
## or in a dependency are skipped, because a project's reader cannot change those
## lines and the line that called them is the one that spent the opcode.
##
## "The project's own" is decided against the SOURCES the rows are placed
## against: a `file_map` entry is the project's file when its path ends in that
## source's project-relative path AND its text is that source's text. Comparing
## the text rather than the folder is what makes this a pure rule over what a
## host already sends (no root to canonicalise through symlinks), and a file
## saved after the compile honestly stops being placed until the re-measure the
## save starts.

import std/[base64, json, strutils, tables]

import ../../../common/[noir_constraints, raw_inflate]
from ../../../ct_test/frameworks/noir_test_syntax import NoirSourceFile
from ./noir_anchor_producer import LocationNode, NoirSpan, readCallStackTree,
  callStackSpans

const
  AcirListingHeader = "Compiled ACIR for "
    ## The line `--print-acir` prints above each package's listing.
  OpcodeHasNoSourceReason* =
    "the compiler recorded no source position for this opcode"
  OpcodeOutsideProjectReason* =
    "the compiler places this opcode only in code outside this project's " &
    "sources"
  OpcodeNoDebugSymbolsReason* =
    "this compile's debug symbols could not be read, so its opcodes are " &
    "not placed"
  ListingDisagreesText* =
    "The compiler's printed opcodes do not add up to its totals, so only the " &
    "totals are shown."
  ListingOfWorkspaceText* =
    "This workspace printed one listing per package, and these totals are " &
    "the first package's alone, so only the totals are shown."
  NoListingText* =
    "The compiler printed no opcodes for this project, so only the totals " &
    "are shown."

proc splitInfoOutput*(output: string): tuple[listing, info: string] =
  ## `nargo info --json --print-acir`'s standard output, split into the printed
  ## listing and the JSON report after it. No printed line starts with `{`: a
  ## listing's lines are headers, opcode names and numbered Brillig rows.
  let at =
    if output.startsWith("{"): 0
    else: output.find("\n{") + 1
  if at == 0 and not output.startsWith("{"):
    return ("", output)
  (output[0 ..< at], output[at .. ^1])

proc attachListing*(report: ConstraintReport; listing: string): ConstraintReport =
  ## `report`, each function holding its printed opcodes — or holding none, with
  ## `listingAbsence` saying why (see the header).
  result = report
  if report.absence.len > 0:
    return
  if listing.strip().len == 0:
    result.listingAbsence = NoListingText
    return
  if listing.count(AcirListingHeader) > 1:
    result.listingAbsence = ListingOfWorkspaceText
    return
  let printed = reportFromAcirListing(listing, report.package,
                                       report.provenance)
  if printed.absence.len > 0:
    result.listingAbsence = NoListingText
    return
  var acir, unconstrained: seq[ConstraintFunction] = @[]
  for fn in printed.functions:
    if fn.kind == cfkAcir: acir.add fn else: unconstrained.add fn
  var nextAcir, nextUnconstrained = 0
  for fn in result.functions.mitems:
    if fn.kind == cfkAcir:
      if nextAcir >= acir.len or acir[nextAcir].opcodes != fn.opcodes:
        result = report
        result.listingAbsence = ListingDisagreesText
        return
      fn.rows = acir[nextAcir].rows
      inc nextAcir
    else:
      if nextUnconstrained >= unconstrained.len or
         unconstrained[nextUnconstrained].name != fn.name or
         unconstrained[nextUnconstrained].opcodes != fn.opcodes:
        result = report
        result.listingAbsence = ListingDisagreesText
        return
      fn.rows = unconstrained[nextUnconstrained].rows
      inc nextUnconstrained
  if nextAcir != acir.len or nextUnconstrained != unconstrained.len:
    result = report
    result.listingAbsence = ListingDisagreesText

proc decodedDebugSymbols*(field: JsonNode): JsonNode =
  ## `debug_symbols` as a document, nil when it cannot be read: base64 of raw
  ## deflate of JSON as `nargo` writes it, or an already-decoded object. The
  ## `except` is bare for `parseNargoInfoJson`'s reason: on the JavaScript
  ## backend a malformed document raises a foreign exception.
  if field.isNil:
    return nil
  if field.kind == JObject:
    return field
  if field.kind != JString:
    return nil
  try:
    let inflated = inflateRaw(decode(field.getStr))
    if not inflated.ok:
      return nil
    result = parseJson(inflated.bytes)
  except:
    result = nil

type
  ProjectFile = object
    path: string
      ## Project-relative.
    text: string

proc projectFilesOf(fileMap: JsonNode;
                    sources: seq[NoirSourceFile]): Table[int, ProjectFile] =
  ## The `file_map` entries that are the project's own sources, by file id.
  result = initTable[int, ProjectFile]()
  if fileMap.isNil or fileMap.kind != JObject:
    return
  for key, entry in fileMap:
    if entry.kind != JObject or not entry.hasKey("path") or
       not entry.hasKey("source") or entry["path"].kind != JString or
       entry["source"].kind != JString:
      continue
    var id = -1
    try: id = parseInt(key)
    except ValueError: continue
    let path = entry["path"].getStr.replace('\\', '/')
    let text = entry["source"].getStr
    for source in sources:
      if (path == source.path or path.endsWith("/" & source.path)) and
         text == source.content:
        result[id] = ProjectFile(path: source.path, text: text)
        break

proc positionOf(text: string; offset: int): tuple[line, column: int] =
  ## The 1-based line and column of byte `offset`, a column counting characters
  ## rather than UTF-8 bytes.
  result = (1, 1)
  for i in 0 ..< min(offset, text.len):
    if text[i] == '\n':
      inc result.line
      result.column = 1
    elif (ord(text[i]) and 0xC0) != 0x80:
      inc result.column

proc placeOfStack(tree: seq[LocationNode]; stack: int;
                  files: Table[int, ProjectFile]): ConstraintOpcodePlace =
  ## The innermost frame of call stack `stack` in the project's sources.
  let frames = callStackSpans(tree, stack)
  if frames.len == 0:
    return ConstraintOpcodePlace(reason: OpcodeHasNoSourceReason)
  for i in countdown(frames.len - 1, 0):
    let frame: NoirSpan = frames[i]
    if frame.fileId in files:
      let file = files[frame.fileId]
      if frame.startByte >= 0 and frame.startByte <= file.text.len:
        let (line, column) = positionOf(file.text, frame.startByte)
        return ConstraintOpcodePlace(placed: true, path: file.path, line: line,
                                     column: column)
  ConstraintOpcodePlace(reason: OpcodeOutsideProjectReason)

proc treeOf(info: JsonNode): seq[LocationNode] =
  if info.hasKey("location_tree") and info["location_tree"].kind == JObject and
     info["location_tree"].hasKey("locations"):
    readCallStackTree(info["location_tree"]["locations"])
  else:
    @[]

proc placeOpcodes*(report: ConstraintReport; artefact: string;
                   sources: seq[NoirSourceFile]): ConstraintReport =
  ## `report` with each printed opcode's place, read from the text of the
  ## compile's artefact; every opcode says why when it has none. A report with
  ## no printed opcodes is returned as it is.
  result = report
  if not report.hasListing():
    return
  var unread = false
  var infos: seq[JsonNode] = @[]
  var files = initTable[int, ProjectFile]()
  try:
    let parsed = parseJson(artefact)
    let symbols = decodedDebugSymbols(
      if parsed.kind == JObject and parsed.hasKey("debug_symbols"):
        parsed["debug_symbols"]
      else: nil)
    if symbols.isNil or symbols.kind != JObject or
       not symbols.hasKey("debug_infos") or
       symbols["debug_infos"].kind != JArray:
      unread = true
    else:
      for info in symbols["debug_infos"]:
        infos.add info
      files = projectFilesOf(parsed["file_map"], sources)
  except:
    # Bare: see `decodedDebugSymbols`. The artefact is whatever the project's
    # folder holds, so a malformed one is an expected input.
    unread = true
  var acirIndex, brilligIndex = 0
  for fn in result.functions.mitems:
    let own =
      if fn.kind == cfkAcir: acirIndex else: brilligIndex
    if fn.kind == cfkAcir: inc acirIndex else: inc brilligIndex
    for op in fn.rows.mitems:
      if unread:
        op.place = ConstraintOpcodePlace(reason: OpcodeNoDebugSymbolsReason)
        continue
      op.place = ConstraintOpcodePlace(reason: OpcodeHasNoSourceReason)
      let key = $op.index
      if fn.kind == cfkAcir:
        if own < infos.len and infos[own].kind == JObject and
           infos[own].hasKey("acir_locations"):
          let located = infos[own]["acir_locations"]
          if located.kind == JObject and located.hasKey(key) and
             located[key].kind == JInt:
            op.place = placeOfStack(treeOf(infos[own]), located[key].getInt,
                                    files)
      else:
        # The Brillig map is held by the circuit that calls the function, and
        # its stacks index THAT circuit's tree.
        for info in infos:
          if info.kind != JObject or not info.hasKey("brillig_locations"):
            continue
          let brillig = info["brillig_locations"]
          if brillig.kind != JObject or not brillig.hasKey($own):
            continue
          let located = brillig[$own]
          if located.kind == JObject and located.hasKey(key) and
             located[key].kind == JInt:
            op.place = placeOfStack(treeOf(info), located[key].getInt, files)
            break
