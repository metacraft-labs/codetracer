## The fixture cache's whole-entry rule (`ct_stages.isWholeCachedRecording`):
## an entry `ct record` has not finished, or one that names its program under
## a `.partial` staging folder (the stage recorded there before it recorded in
## place) or at a path that is gone, is absent, and the next run records again.
## So is an rr entry whose `trace_db_metadata.json` names its output folder
## under `.partial` or gone.
## An entry recorded with another recorder, another `ct` or other program
## sources than the run's is absent too (`recordingProvenance`), and an rr
## entry made with another rr than the run's (`recordersFor`, `rrRecorder`).
## Run by `ci/test/scenarios.sh stage-test`.
import std/[json, os, strutils, unittest]
import ./ct_stages

suite "the fixture cache's whole entries":
  let root = getTempDir() / "ct-stage-cache-test-" & $getCurrentProcessId()
  setup:
    removeDir(root)
    createDir(root)
  teardown:
    removeDir(root)

  test "a recording with no marker is whole; with the in-progress marker it is absent":
    let dest = root / "rec-scenario"
    createDir(dest / "rr")           # a shape isUsableTraceDir accepts
    check isWholeCachedRecording(dest)
    writeFile(recordingIncompleteMarker(dest), "in progress")
    check not isWholeCachedRecording(dest)
    removeFile(recordingIncompleteMarker(dest))
    check isWholeCachedRecording(dest)

  test "a program under a .partial folder, or gone, is stale; one that exists is not":
    let staged = root / "rec-scenario.partial"
    createDir(staged)
    writeFile(staged / "prog", "")
    check staleRecordedProgram(staged / "prog")          # exists, but staged
    check staleRecordedProgram(root / "gone" / "prog")   # absolute, missing
    let kept = root / "rec-scenario"
    createDir(kept)
    writeFile(kept / "prog", "")
    check not staleRecordedProgram(kept / "prog")
    check not staleRecordedProgram("")

  test "an rr entry whose metadata names a .partial or gone output folder is absent":
    # As an rr recording of the stock-Nim flow test made before the stage
    # recorded in place left it: `rr/`, and metadata naming the staging folder.
    let dest = root / "src_db-backend_nim_nim_flow_test_nim_rr_stocknim-scenario"
    createDir(dest / "rr")
    writeFile(root / "prog", "")
    proc meta(output: string; sources: seq[string] = @[]) =
      writeFile(dest / "trace_db_metadata.json", $(%*{
        "program": root / "prog", "outputFolder": output,
        "sourceFolders": sources, "lang": 0}))
    meta(dest & ".partial")
    check staleRecordedPaths(dest)
    check not isWholeCachedRecording(dest)
    meta(root / "gone")
    check not isWholeCachedRecording(dest)
    meta(dest, @[dest & ".partial" / "nimcache"])
    check not isWholeCachedRecording(dest)
    # the control: the same entry recorded in place is whole, and a source
    # folder that is merely elsewhere does not make it stale
    meta(dest, @[root / "elsewhere"])
    check not staleRecordedPaths(dest)
    check isWholeCachedRecording(dest)
    # and a program that is gone does
    removeFile(root / "prog")
    check not isWholeCachedRecording(dest)

  test "an entry recorded with another recorder, ct or program sources is absent":
    # The key the cache is read by besides the program's name
    # (`recordingProvenance`): what `ct record` recorded WITH. A recording the
    # old Solana recorder made was replayed after the recorder changed.
    let prog = root / "prog"
    createDir(prog / "src")
    writeFile(prog / "src" / "main.rs", "fn main() {}\n")
    createDir(prog / "target")                 # what a build writes: not a source
    writeFile(prog / "target" / "out.elf", "v1")
    let rec = root / "codetracer-solana-recorder"
    writeFile(rec, "recorder v1")
    let ct = root / "ct"
    writeFile(ct, "ct v1")
    let recorders = @["CODETRACER_SOLANA_RECORDER_PATH=" & rec]
    let dest = root / "prog_solana-scenario"
    let first = recordingProvenance(prog, "", "solana", recorders, ct)
    writeFile(recordingProvenanceFile(dest), first)
    check cachedProvenanceMatches(dest, first)
    # a rebuild changes nothing a recording depends on
    writeFile(prog / "target" / "out.elf", "v2")
    check cachedProvenanceMatches(dest,
      recordingProvenance(prog, "", "solana", recorders, ct))
    # a new recorder binary at the same path is a different recording
    writeFile(rec, "recorder v2")
    check not cachedProvenanceMatches(dest,
      recordingProvenance(prog, "", "solana", recorders, ct))
    writeFile(rec, "recorder v1")
    # so is a recorder at another path, a new ct, an edited source, another --lang
    check not cachedProvenanceMatches(dest, recordingProvenance(prog, "", "solana",
      @["CODETRACER_SOLANA_RECORDER_PATH=" & root / "other"], ct))
    writeFile(ct, "ct v2")
    check not cachedProvenanceMatches(dest,
      recordingProvenance(prog, "", "solana", recorders, ct))
    writeFile(ct, "ct v1")
    writeFile(prog / "src" / "main.rs", "fn main() { let _ = 1; }\n")
    check not cachedProvenanceMatches(dest,
      recordingProvenance(prog, "", "solana", recorders, ct))
    writeFile(prog / "src" / "main.rs", "fn main() {}\n")
    check not cachedProvenanceMatches(dest,
      recordingProvenance(prog, "", "polkavm", recorders, ct))
    # an entry with no provenance at all (recorded before the key) is absent
    removeFile(recordingProvenanceFile(dest))
    check not cachedProvenanceMatches(dest, first)

  test "an rr entry recorded with another rr is absent":
    # The rr decides what an rr recording holds: only CodeTracer's rr writes
    # the program's output (`rr/write_events.txt`), and an entry a stock rr
    # made replayed with an empty Event Log after the environment named
    # CodeTracer's rr again. The rr is found as ct-native-replay finds it.
    let bin = root / "bin"
    createDir(bin)
    let replay = bin / "ct-native-replay"
    writeFile(replay, "#!/bin/sh\n")
    setFilePermissions(replay, {fpUserExec, fpUserRead, fpUserWrite})
    let beside = bin / "rr"
    writeFile(beside, "codetracer rr")
    let given = root / "given-rr"
    writeFile(given, "rr from CT_RR_EXE")
    let savedPath = getEnv("PATH")
    let savedRr = getEnv("CT_RR_EXE")
    putEnv("PATH", bin)
    delEnv("CT_RR_EXE")
    check rrRecorder() == beside            # the rr beside ct-native-replay
    putEnv("CT_RR_EXE", given)
    check rrRecorder() == given             # $CT_RR_EXE first
    check ("rr=" & given) in recordersFor("rr")
    for r in recordersFor(""):
      check not r.startsWith("rr=")         # another backend names no rr
    let prog = root / "prog.pas"
    writeFile(prog, "begin end.\n")
    let ct = root / "ct"
    writeFile(ct, "ct v1")
    let dest = root / "prog_pas_rr-scenario"
    writeFile(recordingProvenanceFile(dest),
      recordingProvenance(prog, "rr", "", recordersFor("rr"), ct))
    check cachedProvenanceMatches(dest,
      recordingProvenance(prog, "rr", "", recordersFor("rr"), ct))
    delEnv("CT_RR_EXE")                     # now the rr beside the replay
    check not cachedProvenanceMatches(dest,
      recordingProvenance(prog, "rr", "", recordersFor("rr"), ct))
    putEnv("PATH", savedPath)
    if savedRr.len > 0: putEnv("CT_RR_EXE", savedRr)
