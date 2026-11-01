## print_trace_streams_test.nim
##
## `ct print` on a `.ct` container streams the decoded document instead of
## holding it, and prints exactly what it printed when it held it.
##
## codetracer-pm
## `issues/2026-10-31-ct-print-full-uses-32-gb-to-decode-an-11-mb-python-trace.md`:
## decoding an 11 MB Python trace (~310 K steps, ~37 K calls) whole reached
## 32 GB. `ct print` did exactly that in every mode: `printCtfsTrace` built
## the whole `--full` document as one `JsonNode` tree with
## `buildFullDocument`, then `--format json` rendered it into one more string
## the size of the output (`echo pretty(doc)`), `--filter markers` filtered
## the tree, and even the default text summary built it only to print the
## metadata, the counts and a marker count.
## `codetracer-trace-format-spec/trace-events.md`, "Assembling an event
## stream", now requires an assembler that writes the stream out to stream
## it, in memory bounded by the container rather than by the output.
##
## The contract checked here:
##
## 1. **Streamed.** On a container shaped like that trace, each mode's peak
##    memory stays under a bound proportional to the container
##    (`memoryBound`), and `--format json`'s stays under a quarter of the
##    output it wrote. An implementation that holds the rendered output, or
##    the tree it is rendered from, cannot meet either: the rendered string
##    alone is the output's size, and the tree is several times larger.
## 2. **Byte-identical.** On a small container, where the in-process tree is
##    affordable, `--format json` is exactly
##    `pretty(buildFullDocument(...), indent = 2)` plus `echo`'s newline,
##    `--filter markers --format json` is the `pretty` of the tree's marker
##    events, and the text summary and the marker table report the tree's
##    metadata, counts and markers.
##
## Each print runs in a child process: this test binary re-executes itself
## with `ChildFlag`, and the child calls the production `runPrint`. A fresh
## process is what makes its peak memory the printer's own (a fork without
## exec would share the parent's pages, and `getrusage(RUSAGE_CHILDREN)` is
## the maximum over every child reaped). Peak memory is `wait4`'s
## `ru_maxrss` together with samples taken while the child runs. On macOS a
## sample is the larger of the resident set and the physical footprint
## (`proc_pid_rusage`): the kernel compresses and swaps a growing process's
## pages, so its resident set stalls while its footprint keeps climbing
## (measured on the issue's trace: a 4.7 GB resident set against a 60 GB
## footprint). The approach is the one
## `codetracer-trace-format-nim/tests/test_ct_print_full_streams.nim` takes
## for `ct-print`.
##
## The child is killed once it passes twice the bound. That cap protects a
## shared host from the defect this test guards against, and it is why the
## unfixed printer fails here in seconds instead of after minutes and
## gigabytes.
##
## No mocks: every container is written by the production writer
## (`MultiStreamTraceWriter`), read by the production reader, and printed by
## the production `runPrint`.

import
  std / [ json, monotimes, options, os, strutils, tempfiles, times,
          unittest ],
  results,
  codetracer_trace_types,
  codetracer_trace_writer / [ call_stream, cbor, io_event_stream,
                              multi_stream_writer,
                              new_trace_reader, full_document_json ],
  ./print_trace

const
  ChildFlag = "--print-trace-streams-child"
    ## argv[1] of a child that prints a container (see `runChildPrint`).
  bigCalls = 30_000
    ## Python-shaped like the issue's trace (37 485 calls over 309 587 exec
    ## records): ~30 K calls over ~280 K exec records. `--format json` writes
    ## ~380 MiB for it.
  bigStepsPerCall = 8
  smallCalls = 40
  smallStepsPerCall = 3
  runLimit = initDuration(minutes = 5)
    ## A safety net, not the detector: the streaming printer writes the large
    ## container in seconds, and a run that is killed here fails the test
    ## rather than hanging the lane.

# ---------------------------------------------------------------------------
# The child: one `ct print` of one container
# ---------------------------------------------------------------------------

proc runChildPrint() =
  ## `<this binary> ChildFlag <format> <filter> <container>`: print the
  ## container with the production entry point, as `ct print` does, and exit.
  let opts = PrintOptions(
    format: paramStr(2),
    filter: (if paramStr(3) == "-": "" else: paramStr(3)),
    path: paramStr(4))
  runPrint(opts)
  quit(0)

# Must come before any `suite`: the child prints, it does not run tests.
if paramCount() == 4 and paramStr(1) == ChildFlag:
  runChildPrint()

when defined(posix):
  # The child is started with `fork` + `execv` and measured with `wait4`. On
  # a host without them the suite reports itself skipped instead of failing
  # to compile.
  import std/posix

  # ---------------------------------------------------------------------------
  # Running a child, measured
  # ---------------------------------------------------------------------------

  proc c_exit(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

  when defined(macosx):
    type RusageInfoV0 {.importc: "struct rusage_info_v0",
        header: "<libproc.h>".} = object
      ri_resident_size: uint64
      ri_phys_footprint: uint64
    proc proc_pid_rusage(pid: cint, flavor: cint, buffer: pointer): cint
      {.importc, header: "<libproc.h>".}

  proc currentMemoryBytes(pid: Pid): int64 =
    ## The child's memory right now, or 0 when it cannot be read: on macOS the
    ## larger of its resident set and its physical footprint (see the module
    ## header), on Linux its resident set.
    when defined(macosx):
      var info: RusageInfoV0
      if proc_pid_rusage(cint(pid), 0, addr info) == 0:  # RUSAGE_INFO_V0
        return int64(max(info.ri_resident_size, info.ri_phys_footprint))
    elif defined(linux):
      try:
        let fields = readFile("/proc/" & $pid & "/statm").splitWhitespace()
        return parseBiggestInt(fields[1]) * int64(sysconf(SC_PAGESIZE))
      except CatchableError:
        discard
    0

  type Measured = object
    exitCode: int          ## -1 when the child was killed by a signal
    signal: int
    timedOut: bool
    overMemoryCap: bool
    peakBytes: int64
      ## The larger of `wait4`'s peak resident set and the largest
      ## `currentMemoryBytes` sampled while the child ran.
    seconds: float
    stdoutBytes: int64

  proc runPrintMeasured(format, filter, container, stdoutPath, stderrPath: string,
      memoryCap = high(int64)): Measured =
    ## Print `container` in a child (`runChildPrint`), stdout and stderr
    ## redirected to files; kill it after `runLimit` or once its memory passes
    ## `memoryCap`. Returns its exit, its peak memory and how much it wrote.
    let self = getAppFilename()
    let argvSeq = @[self, ChildFlag, format,
      (if filter.len == 0: "-" else: filter), container]
    let argv = allocCStringArray(argvSeq)
    defer: deallocCStringArray(argv)
    # Converted before the fork: the child makes only async-signal-safe calls
    # until `execv`.
    let outC = stdoutPath.cstring
    let errC = stderrPath.cstring
    let selfC = self.cstring
    let started = getMonoTime()
    let pid = fork()
    if pid == 0:
      let fo = posix.open(outC, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
      let fe = posix.open(errC, O_WRONLY or O_CREAT or O_TRUNC, Mode(0o600))
      if fo < 0 or fe < 0 or dup2(fo, 1) < 0 or dup2(fe, 2) < 0:
        c_exit(126)
      discard execv(selfC, argv)
      c_exit(127)
    doAssert pid > 0, "fork failed: " & osErrorMsg(osLastError())
    var status: cint
    var ru: Rusage
    var sampledPeak = 0'i64
    while true:
      let r = wait4(pid, addr status, WNOHANG, addr ru)
      if r == pid:
        break
      if r < 0 and errno != EINTR:
        doAssert false, "wait4 failed: " & osErrorMsg(osLastError())
      let now = currentMemoryBytes(pid)
      sampledPeak = max(sampledPeak, now)
      let overTime = getMonoTime() - started > runLimit
      let overMemory = not overTime and now > memoryCap
      if overTime or overMemory:
        discard kill(pid, SIGKILL)
        result.timedOut = overTime
        result.overMemoryCap = overMemory
        while wait4(pid, addr status, 0, addr ru) < 0 and errno == EINTR:
          discard
        break
      sleep(20)
    result.seconds = float((getMonoTime() - started).inMilliseconds) / 1000.0
    # `ru_maxrss` is bytes on macOS and KiB on Linux.
    when defined(macosx):
      result.peakBytes = int64(ru.ru_maxrss)
    else:
      result.peakBytes = int64(ru.ru_maxrss) * 1024
    result.peakBytes = max(result.peakBytes, sampledPeak)
    if WIFEXITED(status):
      result.exitCode = int(WEXITSTATUS(status))
    else:
      result.exitCode = -1
      result.signal = int(WTERMSIG(status))
    result.stdoutBytes = int64(getFileSize(stdoutPath))

  proc mib(n: int64): string = formatFloat(float(n) / 1048576.0, ffDecimal, 1) & " MiB"

  proc describe(m: Measured): string =
    "exit " & $m.exitCode &
      (if m.signal != 0: " (signal " & $m.signal & ")" else: "") &
      (if m.timedOut: ", KILLED after " & $runLimit.inSeconds & " s" else: "") &
      (if m.overMemoryCap: ", KILLED at the memory cap" else: "") &
      ", " & formatFloat(m.seconds, ffDecimal, 1) & " s, peak memory " &
      mib(m.peakBytes) & ", wrote " & mib(m.stdoutBytes)

  # ---------------------------------------------------------------------------
  # Fixtures, written by the production writer
  # ---------------------------------------------------------------------------

  proc encodeValue(v: ValueRecord): seq[byte] =
    var enc = CborEncoder.init()
    enc.encodeCborValueRecord(v)
    enc.getBytes()

  proc toBytes(s: string): seq[byte] =
    result = newSeq[byte](s.len)
    for i, c in s: result[i] = byte(c)

  proc writePythonShaped(path: string, calls, stepsPerCall, chunkSize: int) =
    ## A module body that calls `calls` functions one after another, with a
    ## module-level step between calls: the shape of a recorded `import`, which
    ## is what the issue's trace is. Every step carries three variables (an
    ## int, a string and a list), every fourth call makes a nested call, a few
    ## raise and catch, and the tail writes IO, two correlation markers (one at
    ## a step past the last, which the document prints after the step loop) and
    ## one IO event whose JSON metadata is not a marker, so every mode of
    ## `ct print` has something to report and something to leave out.
    var w = initMultiStreamWriter(path, "python", chunkSize = chunkSize).get()
    w.metadata.workdir = "/wd"
    w.metadata.args = @["-c", "import black"]
    let pMod = w.registerPath("/wd/main.py").get()
    let pLib = w.registerPath("/wd/lib/black/__init__.py").get()
    let fnModule = w.registerFunction("<module>").get()
    let fnVisit = w.registerFunction("visit").get()
    let fnLeaf = w.registerFunction("leaf").get()
    let vnI = w.registerVarname("i").get()
    let vnName = w.registerVarname("name").get()
    let vnItems = w.registerVarname("items").get()
    let vnN = w.registerVarname("n").get()
    let tInt = TypeId(w.registerType("int").get())
    let tStr = TypeId(w.registerType("str").get())
    let tList = TypeId(w.registerType("list").get())
    let tExc = w.registerType("ValueError").get()

    proc vars(i, s: int): seq[VariableValue] =
      @[
        VariableValue(varnameId: vnI, data: encodeValue(
          ValueRecord(kind: vrkInt, intVal: int64(i * 31 + s), intTypeId: tInt))),
        VariableValue(varnameId: vnName, data: encodeValue(
          ValueRecord(kind: vrkString, text: "node-" & $i & "-" & $s,
            strTypeId: tStr))),
        VariableValue(varnameId: vnItems, data: encodeValue(
          ValueRecord(kind: vrkSequence, isSlice: false, seqTypeId: tList,
            seqElements: @[
              ValueRecord(kind: vrkInt, intVal: int64(i), intTypeId: tInt),
              ValueRecord(kind: vrkInt, intVal: int64(s), intTypeId: tInt)])))]

    proc arg(i: int): seq[CallArg] =
      @[CallArg(varnameId: vnN, value: encodeValue(
        ValueRecord(kind: vrkInt, intVal: int64(i), intTypeId: tInt)))]

    proc ret(i: int): seq[byte] =
      encodeValue(ValueRecord(kind: vrkInt, intVal: int64(i * 2), intTypeId: tInt))

    doAssert w.registerStep(pMod, 1, vars(0, 0)).isOk
    doAssert w.registerCall(fnModule, @[]).isOk
    for i in 0 ..< calls:
      doAssert w.registerStep(pMod, uint64(2 + i mod 50), vars(i, 0)).isOk
      if i == 3:
        doAssert w.registerIOEvent(elkWrite, toBytes("hello\n")).isOk
      doAssert w.registerCall(fnVisit, arg(i)).isOk
      for s in 0 ..< stepsPerCall:
        doAssert w.registerStep(pLib, uint64(10 + s), vars(i, s + 1)).isOk
        if s == 1 and i mod 4 == 1:
          doAssert w.registerCall(fnLeaf, arg(-i)).isOk
          doAssert w.registerStep(pLib, 40, vars(i, 99)).isOk
          doAssert w.registerReturn(ret(-i)).isOk
        if s == 0 and i mod 97 == 5:
          doAssert w.registerRaise(tExc, toBytes("bad node " & $i)).isOk
          doAssert w.registerCatch(tExc).isOk
      doAssert w.registerReturn(ret(i)).isOk

    doAssert w.registerStep(pMod, 60, vars(calls, 0)).isOk
    doAssert w.registerIOEvent(elkWriteOther, toBytes("warning\n")).isOk
    doAssert w.registerCorrelationMarker("send", "edge", "k-1",
      showValue = "42").isOk
    # JSON metadata that is not a marker payload (no `key_value`): must not
    # be counted.
    doAssert w.registerIOEvent(elkWrite, toBytes("almost\n"),
      metadata = toBytes("""{"boundary_id": "edge", "direction": "recv"}""")).isOk
    # A marker whose step lies past the last one: printed by the drain after
    # the step loop, and counted all the same.
    doAssert w.registerIOEvent(elkWrite, toBytes("late\n"),
      metadata = toBytes(
        """{"boundary_id": "edge", "direction": "recv", "key_value": "k-2"}"""),
      stepId = some(1_000_000_000'u64)).isOk
    doAssert w.registerReturn(ret(calls)).isOk
    doAssert w.close().isOk
    doAssert w.closeCtfs().isOk

  proc inProcessDocument(path: string): JsonNode =
    ## The whole document as the tree `ct print` used to hold: affordable on
    ## the small container only.
    var reader = openNewTrace(path).get()
    buildFullDocument(reader, FullOpts())

  proc markerEvents(doc: JsonNode): seq[JsonNode] =
    for ev in doc["events"].elems:
      if isCorrelationMarker(ev):
        result.add(ev)

  proc firstDifference(a, b: string): string =
    ## Where two texts first differ, with a little context, for the failure
    ## message (the texts themselves can be megabytes).
    var i = 0
    while i < a.len and i < b.len and a[i] == b[i]: inc i
    let lo = max(0, i - 200)
    "first difference at byte " & $i & " (lengths " & $a.len & " / " & $b.len &
      ")\n--- ct print:\n" & a[lo ..< min(a.len, i + 200)] &
      "\n--- expected:\n" & b[lo ..< min(b.len, i + 200)]

  proc memoryBound(containerBytes: int64): int64 =
    ## What a streaming `ct print` may hold, as a function of the container:
    ##
    ## * the container image, read whole by the reader and again by the span
    ##   stream probe (`containerRequestRows`): 2x;
    ## * one 8-byte position per exec record and the call records and IO
    ##   events kept to order them, bounded by the decompressed streams, which
    ##   compress ~4-8x here: 8x more;
    ## * the reader's bounded chunk caches and the runtime: 96 MiB.
    ##
    ## The printer that held the tree passes it by an order of magnitude long
    ## before it finishes.
    96 * 1024 * 1024 + 10 * containerBytes

  suite "ct print streams a .ct container (codetracer-pm 2026-10-31)":
    let dir = createTempDir("ct_print_trace_streams_", "")

    test "every mode's output matches the in-process document":
      let container = dir / "small.ct"
      writePythonShaped(container, smallCalls, smallStepsPerCall, chunkSize = 16)
      let doc = inProcessDocument(container)
      let markers = markerEvents(doc)
      # Non-degeneracy: a fixture without markers would let a filter that drops
      # every event pass, and one without a near miss would let a count that
      # takes every IO event with JSON metadata pass.
      check markers.len == 2
      let outPath = dir / "small.out"
      let errPath = dir / "small.err"

      proc printed(format, filter: string): string =
        let m = runPrintMeasured(format, filter, container, outPath, errPath)
        doAssert m.exitCode == 0 and not m.timedOut,
          "ct print --format " & format & " --filter " & filter & ": " &
          describe(m) & "\nstderr:\n" & readFile(errPath)
        readFile(outPath)

      # `--format json`: the document, byte for byte.
      let full = printed("json", "")
      let expectedFull = pretty(doc, indent = 2) & "\n"
      check full == expectedFull
      if full != expectedFull:
        echo firstDifference(full, expectedFull)

      # `--filter markers --format json`: the tree's marker events.
      var arr = newJArray()
      for m in markers: arr.add(m)
      let expectedMarkers = pretty(arr, indent = 2) & "\n"
      let markersJson = printed("json", "markers")
      check markersJson == expectedMarkers
      if markersJson != expectedMarkers:
        echo firstDifference(markersJson, expectedMarkers)

      # `--filter markers`: the table names the document's program and lists
      # its markers.
      let table = printed("text", "markers")
      check table.startsWith(
        "program: " & doc["metadata"]["program"].getStr() & "\n" &
        "correlation markers: 2\n")
      check "send" in table and "k-1" in table and "recv" in table and
        "k-2" in table

      # The text summary: the document's metadata, every count in its order,
      # and its marker count.
      var expectedSummary = "CTFS trace: " & container & "\n" &
        "  Program:  " & doc["metadata"]["program"].getStr() & "\n" &
        "  Workdir:  " & doc["metadata"]["workdir"].getStr() & "\n" &
        "  Recorder: " & doc["metadata"]["recorder"].getStr() & "\n"
      for k, v in doc["counts"].pairs:
        expectedSummary.add("  " & k & ": " & $v & "\n")
      expectedSummary.add("  Correlation markers: " & $markers.len & "\n")
      let summary = printed("text", "")
      check summary.startsWith(expectedSummary)
      if not summary.startsWith(expectedSummary):
        echo firstDifference(summary, expectedSummary)

    test "a Python-shaped trace prints in memory bounded by the container":
      let container = dir / "large.ct"
      writePythonShaped(container, bigCalls, bigStepsPerCall, chunkSize = 4096)
      let containerBytes = int64(getFileSize(container))
      let bound = memoryBound(containerBytes)
      let what = "a " & mib(containerBytes) & " container (" & $bigCalls &
        " calls)"
      let outPath = dir / "large.out"
      let errPath = dir / "large.err"

      # `--filter markers --format json` collects its markers as the table
      # does; its text is checked on the small container.
      for (format, filter) in [("json", ""), ("text", ""), ("text", "markers")]:
        let label = "ct print --format " & format &
          (if filter.len > 0: " --filter " & filter else: "")
        let m = runPrintMeasured(format, filter, container, outPath, errPath,
          memoryCap = 2 * bound)
        echo "  " & label & " on " & what & ": " & describe(m)
        check not m.overMemoryCap
        check not m.timedOut
        check m.exitCode == 0
        check m.peakBytes < bound
        if format == "json" and filter.len == 0:
          # The rendered output alone is this size, and the tree it would be
          # rendered from is larger: a printer that holds either cannot stay
          # under a quarter of it.
          check m.peakBytes * 4 < m.stdoutBytes
          # And it is the whole document, not a truncated one: one `step`
          # entry per step the counts declare.
          var steps = 0
          for line in lines(outPath):
            if line == "      \"kind\": \"step\",": inc steps
          var reader = openNewTrace(container).get()
          check steps == int(reader.logicalStepCount().get())
        removeFile(outPath)

    removeDir(dir)
else:
  suite "ct print streams a .ct container (codetracer-pm 2026-10-31)":
    test "measuring a child print needs fork, execv and wait4":
      skip()
