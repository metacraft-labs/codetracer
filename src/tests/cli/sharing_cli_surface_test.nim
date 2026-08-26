## AS-3 — every flag the sharing path *tells a user to type* must exist.
##
## Spec: `codetracer-specs/Sharing/Artifact-Store.md` §8 defects 16 and 17.
##
## ## Why this exists
##
## AS-3 shipped two defects of exactly one shape, and neither was visible to
## any suite in the repository:
##
## 1. `artifact_store.nim` told the user to run `ct download --password`. There
##    is no `--password`; the surface is `--password-file` / `--password-stdin`.
##    A user following that message got a parse error.
## 2. The stdin source was first spelled `--password-file -`, and `confutils`
##    parses a bare `-` as the start of another option, so the password
##    silently arrived as nothing.
##
## Both slipped past because **nothing drove the CLI surface**. Every ViewModel
## suite asserts pure functions, and the round-trip suite asserts HTTP; the
## argument parser and the strings that name its flags sat between them,
## untested. So this suite takes the built `ct` binary as its subject.
##
## ## What it asserts
##
## * every `--flag` that appears in a *string literal* under
##   `src/ct/online_sharing/` is a flag `ct` actually accepts, on some
##   subcommand — which is the check that catches a message naming a flag that
##   does not exist;
## * the sharing subcommands accept the flags this milestone added, and reject
##   the retired spelling;
## * `--password-stdin` and `--password-file` are mutually exclusive, and a
##   bare `-` is refused rather than silently ignored — the refusal that must
##   fire in the direction where silence uploads in the clear.
##
## ## On mocking
##
## Nothing is mocked. The subject is `src/build-debug/bin/ct`, the shipped
## binary, run as a user runs it. `just build-once` must have produced it;
## a missing binary is a loud failure rather than a skip, because "the CLI is
## untested" is the condition this file exists to end.
##
## Runs in `just test-cli-record`, which globs `src/tests/cli`.

import std/[algorithm, os, osproc, sets, strutils, unittest]

const
  CtBinary = "src/build-debug/bin/ct"
  SharingDir = "src/ct/online_sharing"

  ScannedSubcommands = ["upload", "download", "record", "replay", "review"]
    ## The subcommands whose help is scanned for the flag vocabulary. The
    ## sharing modules' messages point at these and no others.

  # Flags a sharing message may legitimately name that `ct` itself does not
  # accept, each with the reason it is here. An unexplained entry is the defect
  # this file is about, one level up — so the reason is a comment beside the
  # entry, and a reviewer can see an addition that has none.
  FlagsNotCtsOwn = [
    # `ct-mcr record --split` — the RECORDER's flag, named when explaining
    # what a pre-split slice directory is.
    "--split",
    # `ct-mcr export --portable` — the RECORDER's flag again, named by the
    # enrichment step's warnings. `ct upload` has `--no-portable`, which is a
    # different flag on a different binary; the scan finding both is the point.
    "--portable",
    # Not a message at all: `remote.nim` builds this into the argv of a
    # SUBPROCESS. The scan cannot tell a printed string from a constructed
    # argument list, so this one is listed rather than the rule weakened.
    "--binary-name",
  ]

proc runCt(arguments: openArray[string]): tuple[output: string, code: int] =
  ## Run the shipped binary and return everything it said.
  doAssert fileExists(CtBinary),
    CtBinary & " is missing — run `just build-once` first. This suite drives " &
    "the real CLI on purpose and must not be skipped when it cannot."
  let outcome = execCmdEx(CtBinary & " " & arguments.join(" "))
  (output: outcome.output, code: outcome.exitCode)

proc flagsIn(text: string): HashSet[string] =
  ## Every `--flag` token in `text`, normalised: an `=` or trailing
  ## punctuation ends the name.
  result = initHashSet[string]()
  var i = 0
  while i < text.len:
    if text[i] == '-' and i + 1 < text.len and text[i + 1] == '-':
      var j = i + 2
      while j < text.len and (text[j].isAlphaNumeric or text[j] == '-'):
        inc j
      let name = text[i ..< j]
      # `--` alone, and a trailing hyphen, are not flag names.
      if name.len > 2 and not name.endsWith("-"):
        result.incl name
      i = j
    else:
      inc i

proc stringLiteralsOf(path: string): string =
  ## The contents of every double-quoted string literal in a Nim file,
  ## concatenated.
  ##
  ## Comments are deliberately excluded: a comment may discuss a flag that
  ## does not exist (a retired one, a proposal), and only what is printed to a
  ## user is a promise. This is a lexer good enough for that distinction —
  ## it tracks `#` outside strings and `\` escapes inside them.
  result = ""
  for line in readFile(path).splitLines():
    var inString = false
    var i = 0
    while i < line.len:
      let c = line[i]
      if inString:
        if c == '\\':
          inc i
        elif c == '"':
          inString = false
          # A separator per LITERAL, not per line. Without it two adjacent
          # literals concatenate — `"--binary-name"` and `"ct remote"` scanned
          # as the single flag `--binary-namect`, which is a false report and
          # exactly the kind a guard must not make.
          result.add ' '
        else:
          result.add c
      else:
        if c == '#':
          break
        elif c == '"':
          inString = true
      inc i
    result.add ' '

suite "AS-3 — the sharing path never names a flag that does not exist":

  test "every --flag in a sharing message is one the CLI accepts":
    # §8 defect 16's sibling, and the guard the coordinator asked for: the
    # message `ct download --password` was a promise the binary could not keep.
    var accepted = initHashSet[string]()
    for subcommand in ScannedSubcommands:
      let help = runCt([subcommand, "--help"])
      check help.output.len > 0
      accepted = accepted + flagsIn(help.output)
    check accepted.len > 10   # the scan found a real vocabulary, not nothing
    check "--password-file" in accepted
    check "--password-stdin" in accepted
    check "--encrypt" in accepted

    var offenders: seq[string] = @[]
    for entry in walkDir(SharingDir):
      if entry.kind != pcFile or not entry.path.endsWith(".nim"):
        continue
      # Test files talk about flags in assertions, not to users.
      if entry.path.endsWith("_test.nim"):
        continue
      for flag in flagsIn(stringLiteralsOf(entry.path)):
        if flag in accepted:
          continue
        if flag in FlagsNotCtsOwn:
          continue
        offenders.add extractFilename(entry.path) & ": " & flag
    offenders.sort()
    # Named, so the failure says which file and which flag rather than only
    # that the count is wrong.
    check offenders == newSeq[string]()

  test "no allowlist entry is dead":
    # AS-4. `--output` was on the allowlist with the comment "`ct review
    # collect --output <DIR>` — named when a review dataset directory is
    # missing its `review.json`", implying `ct` does not accept it. It does:
    # `ct review --help` lists it, so the entry never fired and the comment
    # said the opposite of the truth. A dead entry is worse than none, because
    # it would silence a genuine miss the day `--output` were removed.
    #
    # So the allowlist is now guarded the same way the messages are: an entry
    # the CLI *does* accept is an entry that is doing nothing, and it is named.
    var accepted = initHashSet[string]()
    for subcommand in ScannedSubcommands:
      accepted = accepted + flagsIn(runCt([subcommand, "--help"]).output)
    var dead: seq[string] = @[]
    for entry in FlagsNotCtsOwn:
      if entry in accepted:
        dead.add entry
    dead.sort()
    check dead == newSeq[string]()

suite "AS-3 — the sharing CLI accepts what this milestone documents":

  test "ct upload takes --encrypt, --password-file and --password-stdin":
    let help = runCt(["upload", "--help"])
    check "--encrypt" in help.output
    check "--password-file" in help.output
    check "--password-stdin" in help.output
    # The help must not advertise the retired spelling.
    check "password-file -" notin help.output
    check "'-' for standard input" notin help.output

  test "ct download takes --password-file and --password-stdin":
    let help = runCt(["download", "--help"])
    check "--password-file" in help.output
    check "--password-stdin" in help.output
    check "'-' for standard input" notin help.output

  test "an unknown password flag is refused by the parser":
    # The state the phantom message would have left a user in.
    let refused = runCt(["upload", "--password=hunter2"])
    check refused.code != 0
    check "password" in refused.output.toLowerAscii()

suite "AS-3 — a password source is unambiguous at the command line":
  ## Driven against the real binary because the failures being guarded are
  ## *parsing* outcomes. `secretSource`'s decision table is asserted purely in
  ## `artifact_protection_vm_test.nim`; this is the half that proves the
  ## decision is reached with the values the parser actually produces.

  setup:
    let datasetDir = getTempDir() / "ct-sharing-cli-surface"
    removeDir(datasetDir)
    createDir(datasetDir)
    writeFile(datasetDir / "review.json", """{"commitSha":"a","baseCommitSha":"b"}""")

  teardown:
    removeDir(datasetDir)

  test "--password-stdin and --password-file together are refused":
    let passwordFile = datasetDir / "pw.txt"
    writeFile(passwordFile, "correct horse battery staple")
    let refused = runCt(["upload", "--artifact=" & datasetDir, "--encrypt",
      "--password-stdin", "--password-file=" & passwordFile])
    check "mutually" in refused.output
    check "one source" in refused.output

  test "a bare - is refused rather than silently ignored":
    # §8 defect 16, and the half that survived the first fix. The retired
    # spelling is the conventional Unix one, so people will type it; before
    # this, `--password-file -` WITHOUT `--encrypt` proceeded to upload in the
    # clear, which is the unsafe direction.
    for arguments in [
        @["upload", "--artifact=" & datasetDir, "--password-file", "-"],
        @["upload", "--artifact=" & datasetDir, "--encrypt",
          "--password-file", "-"]]:
      checkpoint(arguments.join(" "))
      let refused = runCt(arguments)
      check "bare `-` is not a password source" in refused.output
      check "--password-stdin" in refused.output
      # Whatever else happens, it must not have got as far as uploading.
      check "uploaded" notin refused.output.toLowerAscii()

  test "a password source without --encrypt is refused":
    let passwordFile = datasetDir / "pw.txt"
    writeFile(passwordFile, "correct horse battery staple")
    let refused = runCt(["upload", "--artifact=" & datasetDir,
      "--password-file=" & passwordFile])
    check "without --encrypt" in refused.output
    check "unencrypted" in refused.output

  test "--encrypt discloses before it asks, and refuses a short password":
    let passwordFile = datasetDir / "short.txt"
    writeFile(passwordFile, "hunter2")
    let refused = runCt(["upload", "--artifact=" & datasetDir, "--encrypt",
      "--password-file=" & passwordFile])
    # The disclosure comes FIRST — AS-3's fourth deliverable is that "nothing"
    # is an acceptable answer to "what if I lose it" only if it is said in
    # advance, and "in advance" means before the password is even read.
    let disclosureAt = refused.output.find("If you lose the password")
    let refusalAt = refused.output.find("at least 8 characters")
    check disclosureAt >= 0
    check refusalAt >= 0
    check disclosureAt < refusalAt
    check "Nothing." in refused.output
    # …and what stays visible is named, for this kind, before the choice.
    check "commitSha" in refused.output
