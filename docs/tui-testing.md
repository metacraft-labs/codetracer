# Testing the CodeTracer TUI

**Audience:** anyone adding a pane, a widget, a keybinding or a golden to
`src/frontend/tui/`.

**Governing specs:** `codetracer-specs/Front-Ends/CodeTracer-TUI.md` §7 and
`codetracer-specs/Front-Ends/CodeTracer-TUI.milestones.org`
§"Testing architecture". This document is the operational half: which tier to
reach for, what each one can and cannot see, and the one rule that keeps the
Tier-1 goldens honest.

---

## The two tiers, and why there are two

| | Tier 1 | Tier 2 |
|---|---|---|
| what runs | `TerminalTestHarness`, in process | the compiled binary, in a real pty |
| what parses the screen | nothing — the harness *is* the screen | `libvterm`, via `nim-libvterm` |
| driver | `nim-pty` + `TermAssert` | — |
| lane | `just test-tui` | `just test-tui-real-terminal` |
| cost | ~20 ms per case | a compile plus a spawn per case |
| lives in | `src/frontend/tui/tests/` | `src/frontend/tui/tests/real_terminal/` |

Tier 1 mounts a component tree, runs layout, composites strips into a
`ScreenBuffer`, and lets a test assert on `cellAt`, `dumpTree`, `layoutRegion`,
`dirtyRegions`, `stripCacheStats` and `bytesEmitted`. It records six golden
formats: `plaintext.txt`, `ansi.ansi`, `cellmap.json`, `svg.svg`,
`annotated.svg`, `treedump.txt`.

**All six are derived from the same in-process model that produced the ANSI.**
If the compositor's idea of the screen and a terminal's idea of the screen come
apart, Tier 1 cannot see it. It will record and re-verify a wrong screen for as
long as nobody looks.

That is not a hypothetical. The first run of the cross-tier suite
(`tests/real_terminal/test_cross_tier_snapshot_equivalence.nim`) found three
defects, all in sibling libraries, all sitting inside green runs:

1. `isonim-tui`'s compositor never wrote a ghost cell into the composited
   buffer, so `encodeAnsi` emitted a real space after every wide glyph.
   Measured on `┌世界─┐`: the buffer put `┐` at column 6 and a terminal put it
   at column 8 — one column of drift per wide glyph, accumulating.
2. `nim-libvterm`'s `cellAt` raised `RangeDefect` on the trailing half of any
   wide glyph, which took down every consumer that walks a whole screen.
3. `TermAssert`'s `renderPlain` and `renderCellmap` disagreed with isonim-tui's
   encoders about that same trailing half, and did not encode `underline` at
   all.

---

## Which tier to assert in

### Assert at Tier 1

* **A pane's content and semantics.** Which rows exist, what text is in them,
  which cell carries the execution pointer, whether the gutter shows a
  breakpoint, what the status line reads.
* **Layout arithmetic.** Pane regions, disjointness, totality over the cell
  grid, reflow after `h.resize`.
* **Reactivity.** That a ViewModel change reaches the screen after `flush()`.
* **Emission budgets.** `bytesEmitted` after a single step, `stripCacheStats`
  hit rate.

Tier 1 is the per-PR lane. Everything that can be asserted there should be,
because it is two orders of magnitude cheaper and its failures point at one
component.

### Only Tier 2 will do

Anything that involves the terminal **as a peer**. Tier 1 has no peer — it is
both sides of the conversation — so these are not "better" at Tier 2, they are
*unobservable* anywhere else:

| subject | why Tier 1 cannot see it |
|---|---|
| the screen a terminal actually renders | Tier 1's screen is the model that produced the bytes |
| real cell attributes after parsing | a style struct is not a colour a terminal shows |
| SIGWINCH | `h.resize()` is a method call; `setWindowSize` is a kernel signal |
| capability negotiation | what the app negotiated is read from the terminal's side |
| synchronized output (DEC 2026) | the bracketing is in the byte stream, not the model |
| mouse (SGR 1006) | real byte sequences arriving on a real fd |
| keys as bytes | `sendKey("f10")` is an xterm sequence, not a synthesized event |
| cursor position, shape, visibility | the model has no cursor |
| OSC 8 hyperlinks | not represented in the `ScreenBuffer` |
| termios, alt-screen, signal-safe restore | there is no tty to leak |
| process lifecycle and exit codes | there is no process |

### The rule

> **A pane's content and semantics are asserted at Tier 1.
> A pane's appearance on a real terminal is asserted ONCE per pane at Tier 2,
> as cross-tier `snap` equality.
> Anything involving the terminal as a peer is asserted only at Tier 2.**

---

## THE RULE FOR A NEW PANE: exactly one equivalence test

**A new pane needs exactly one cross-tier equivalence test. Not zero, and not
one per assertion.**

*Not zero*, because a pane with only Tier-1 goldens has goldens that nothing
has ever checked against a terminal. The equivalence test is what grounds every
other golden that pane records — after it passes once, a Tier-1 golden for that
pane is evidence, and before it does, it is a screenshot of a model.

*Not one per assertion*, because each costs a compile and a spawn, and because
the second one proves nothing the first did not. Cross-tier equality is a
property of the RENDERING PATH — compositor, SGR encoder, width table, terminal
parser — and that path does not change between two panes' assertions. Once a
pane's characteristic screen round-trips, its other states are Tier-1 work.

Concretely, adding a pane means:

1. `src/frontend/tui/tests/apps/app_<pane>.nim` — a module exporting
   `buildTree*(r: TerminalRenderer): TerminalNode` and, under
   `when isMainModule`, one call to `snapshotAppMain(buildTree,
   commandLineParams())`.
2. One case in `tests/real_terminal/test_cross_tier_snapshot_equivalence.nim`
   calling `bothGeometries("app_<pane>", paneApp.buildTree)`.
3. Everything else about the pane at Tier 1.

The child app and the Tier-1 half run **the same `buildTree` proc**. That is
what makes the result a statement about the renderer rather than about two
hand-written fixtures that happen to agree.

---

## How the cross-tier comparison works

`src/frontend/tui/testing/dual_snap.nim` is the whole mechanism.

```
runDualSnap(stem, buildTree, cols, rows)
  ├─ Tier 1: newTerminalTestHarness(cols, rows).mount(buildTree)
  │          → six files in test-logs/tui-dual-snap/cases/<case>/tier1/
  ├─ Tier 2: compile tests/apps/<stem>.nim, spawn it under TermAssert
  │          at cols×rows, wait for the frame barrier
  │          → six files in .../tier2/
  └─ compareSnapshotDirs(tier1, tier2)
```

Nothing is written into the repository: everything lands under `test-logs/`,
which `.gitignore` covers.

### What is compared

`plaintext.txt` and `cellmap.json`, projected onto a canonical cell model —
rune, width, foreground, background, attribute set, underline style — because
the two tiers write two different JSON dialects for the same screen.

A divergence report **names the first differing `(row, col)` with both runes
(and their codepoints) and both style sets**. "Screens differ" is not a
diagnosis and this comparison never emits one.

### What is NOT compared, and the doctrine about it

Four files are not compared and two cell fields are not compared. Every one is
a named entry in `CrossTierExclusions` in `dual_snap.nim`, carrying a
justification **and the evidence that established it**, and
`CrossTierExclusionCount` is asserted by the suite so one cannot be added
without the number moving in a diff a reviewer reads.

> **Never loosen the comparison.** There is no tolerance, no "close enough",
> no whitespace-insensitive mode. A difference is either a defect or a named,
> individually justified exclusion. An unexplained exclusion is a review
> failure.
>
> **If you find yourself wanting to relax the check to make it pass, stop.**
> The three defects listed at the top of this document were all found that way,
> and all three would have been "an irreducible difference between the tiers"
> to anyone who reached for a tolerance instead of a debugger.

A **canonicalisation** is a different thing and is kept in a different list
(`CrossTierCanonicalisations`). It maps two spellings of one fact onto one
representation — Tier 1's `ckAnsi n` and Tier 2's `ckIndexed n` are the same
colour — and it still FAILS when the fact differs. Confusing the two is how a
comparison quietly stops checking.

The exclusion register is `echo`ed by the suite on every run, pass or fail, so
a reader of a green run can see what it stopped checking — and `checkpoint`ed
again beside any divergence, which is where a reader of a failure wants it. It
has to be an `echo`: `std/unittest` accumulates checkpoints and flushes them
only from `fail()`, so a checkpoint alone would print on a red run and nowhere
else. Note that `run-nim-test-lane.sh` captures a green file's stdout, so read
the register by running the suite binary directly:

```sh
nim c --path:src/frontend/viewmodel --path:../TermAssert/src \
      --path:../TermAssertClient/src --path:../nim-libvterm/src \
      -d:isonimTuiGrammarArchive=$PWD/build/grammars/libcodetracer_tui_grammars.a \
      -r src/frontend/tui/tests/real_terminal/test_cross_tier_snapshot_equivalence.nim
```

### What cross-tier equality cannot catch, and never will

**Cross-tier equality is a DIFFERENTIAL check.** It compares two renderings of
the *same* program: both tiers run the same `buildTree` over the same code under
`app/`. So it is blind by construction to any defect the two renderings share.
A wrong screen painted identically twice compares equal.

This was measured rather than reasoned about. A mutation arm made
`app/views/gutter.lineNumberStyle(gpUnverified)` return the VERIFIED style, so
an `savUnverified` file rendered exactly like the recording's own copy — the one
distinction the source-access seam exists to preserve. `runDualSnap` reported
**0 divergences at both geometries, correctly**: both tiers painted
`indexed:8`. What reddened was the assertion about what the colour MEANS —
`cellAt(row, col).fg.idx == 3'u8` — and nothing else in the tree could have.

> **A Tier-2 case that only compares the tiers asserts that the renderer is
> faithful. It never asserts that the screen is right.** Every colour, glyph or
> position a Tier-2 case relies on for its MEANING must also be asserted
> ABSOLUTELY — `fg.idx == 3'u8`, not "the same as Tier 1".

The corollary matters most where a pane's cross-tier case is the only Tier-2
case it has, which the rule above makes the common shape: adding a pane to
`runDualSnap` buys nothing about that pane's semantics. Semantics are Tier-1
work — except the ones observable only as a real terminal's cell state, colour
and attributes, and those need an absolute assertion here.

---

## Determinism: never sleep, never poll for a needle

`waitForText("line 42", 5s)` is banned in this tree, and it is worth knowing
why. It passes on a **partially painted** frame that happens to contain the
needle, and when it fails it fails as a timeout — a symptom, not a diagnosis,
whose natural remedy ("raise the timeout") is wrong for every cause it can
have. See `codetracer-specs/Testing/Verification-Harness-Traps.md` §3.

Two mechanisms replace it.

### The frame barrier (the cursor)

`encodeAnsi` emits every cell of every row in order, so the last glyph a frame
writes is the bottom-right one and the cursor comes to rest at
`(rows-1, cols-1)` exactly when the frame is complete. It cannot be there
earlier. `dual_snap.waitForCompleteFrame` waits for that, and its failure names
**the cursor position it actually observed**, whether the child is alive, and
what is on the screen — so "still painting", "died on startup" and "painted
something else" are three different reports.

An OSC-title barrier was tried and rejected: libvterm delivers OSC payloads as
string fragments and `nim-libvterm`'s mirror overwrites rather than
accumulates, so a title straddling one of TermAssert's 4096-byte pty reads
would never match.

### The IPC channel (`--test-ipc`)

TermAssert hosts a per-session Unix socket and passes `$TERM_ASSERT_URI` to the
child; `TermAssertClient` lets the child call `screenshot(label)`, which the
harness records into `snapshots()`. That inverts who decides a frame is final:
the app declares it, and the test asserts on the frame the app declared.

**`--test-ipc` is a test-only flag.** It is parsed by
`src/frontend/tui/testing/test_app_runtime.nim` and nowhere else. Three
assertions keep it out of a release build, all in
`tests/test_tui_build_prerequisites.nim`:

* `app/cli.parseTuiCommand` **refuses** it, in every argument position — asked
  of the parser, not of the source text, because a scan for the spelling would
  be reddened by a future comment and satisfied by a rename;
* `TuiHelpText` does not mention it;
* **no module under `testing/` appears in `main.nim`'s resolved import
  closure**, which is what makes the first two more than a convention.

The toolchain says the same thing a fourth way: `test_app_runtime.nim` imports
`term_assert_client`, whose `--path` only the `tui-real-terminal` lane and the
child-app compile line carry, so a release build that reached it would not
compile.

#### The two-channel race, and the handshake that closes it

The pty and the IPC socket are **two unordered channels**. TermAssert's `pump`
reads the pty 4096 bytes at a time and services IPC *between* chunks, so a
child that requested a screenshot immediately after painting would be serviced
with the tail of its own paint still unread — and the harness would record a
partial frame, silently, more often on the larger geometry.

So the child waits to be asked:

```
parent: waitForCompleteFrame(...)     # proves the whole frame is consumed
parent: send("S")
child:  requestScreenshot(label)      # only now
parent: waitForSnapshotLabel(label)
```

No sleep anywhere. What the child still owns is the decision to *answer* —
which is exactly what `--never-settle` withholds, and what the negative arm
measures.

### Three distinguishable failures

`test_ipc_settled_frame.nim` asserts all three, because folding any two of them
together turns a plumbing defect into an application defect in the report:

| state | how it presents |
|---|---|
| the child never painted | `waitForCompleteFrame` fails naming the cursor position it saw |
| the child painted but declined to emit the label | **"label never arrived"**, naming the label, the labels that did arrive (`[]`), `child alive=true`, and the screen |
| the socket was miswired | the child exits `3` before painting with `TERM_ASSERT_URI connect failed: <path>` |

---

## Test-quality rules for this tree

These are not stylistic. Each one is a defect class that has cost a milestone
somewhere in this repository — see
`codetracer-specs/Testing/Silent-Self-Pass-Audit-2026-08-23.md` and
`codetracer-specs/Testing/Verification-Harness-Traps.md`.

1. **No skipped tests for a missing prerequisite.** A missing grammar archive,
   an unbuilt binary, an absent recorder: each FAILS, by name, and names the
   recipe that fixes it. A test that detects a missing prerequisite, returns
   early and is counted PASSED is the defect the silent-self-pass audit
   catalogues. The one sanctioned exception is the fixture corpus's counted
   `MISSING-PREREQ SKIP:` — and an all-skipped run fails the lane.
2. **No `when false`, no bare early return, no `try/except` that turns a
   failure into a pass.**
3. **Count your assertions at runtime.** Every suite here carries
   `const ExpectedAssertions = <n>` on one line (the lane runner reads exactly
   that spelling), a counted `ck` template, and a final case that echoes
   `CHECKS: <n>` and asserts the total. A case that returned early or a loop
   that skipped a member reddens the file on the spot instead of being noticed
   by someone differencing two runs. **Write the number last, from a run.**
4. **Every negative assertion needs a positive twin through the same code
   path.** `assert not contains` is satisfied by an empty haystack. If a scan's
   size is knowable, assert the SIZE, not that it is non-empty: "at least one"
   is satisfied by one member of three.
5. **A mutation arm is a deliverable, not a demonstration.** A comparison that
   cannot be made to fail is indistinguishable from one that is not reading the
   files. The cross-tier suite carries four: a changed rune, a changed style, an
   *excluded* attribute that must NOT fail (with a non-excluded one through the
   same helper that must), and a directory compared with itself, which is
   refused rather than passed.
6. **An expected value must not be produced by the code under test.** Where
   the subject IS a published table, read the publication: CTUI-9's
   `app/tests/test_keymap_no_conflicts.nim` parses §4.2's markdown out of
   `codetracer-specs/Front-Ends/CodeTracer-TUI.md` at run time (located from
   `currentSourcePath()`, not from the working directory) and compares it with
   `app/input/keymap.defaultKeymap()`. A hand-copied table in the test would
   have been written from the same reading that produced the implementation,
   and the two would agree about a misreading. A missing sibling checkout
   FAILS by name — rule 1 applies to an absent oracle exactly as it does to an
   absent grammar archive.
7. **No mocks of ViewModels or trace engines.** Tests load real `.ct`
   containers produced by real recorders driven by a real `replay-server`. The
   permitted fakes are `Pilot` synthetic input and `TestClock` virtual time, at
   the hardware boundary, each justified in the header of the file that uses
   it; and `MockBackendService` in exactly one file, CTUI-0's stack-compiles
   test.

---

## Running it

```sh
just tui-prereqs                # submodules + build/grammars/*.a  (idempotent)
just build-tui                  # build/bin/codetracer-tui
just test-tui                   # Tier 1
just test-tui-real-terminal     # Tier 2 (depends on build-tui)
```

Both lanes are discovered, not enumerated: `ci/lib/test-lane-files.sh` globs
`src/frontend/tui/tests/test_*.nim` **and** `src/frontend/tui/app/tests/test_*.nim`
one level deep for `tui`, and finds
`src/frontend/tui/tests/real_terminal/test_*.nim` recursively for
`tui-real-terminal`. Adding a suite needs no edit there.

`app/tests/` is a Tier-1 directory with one extra property, and it is the
reason CTUI-3's layout suites live there rather than in `tests/`:
**`tests/test_tui_facade_boundary.nim` walks every `.nim` file under `app/`,
including those.** A suite placed there cannot import `host/`, `std/posix` or
`std/osproc` without reddening that guard. So "the reflow suite must not reach
for SIGWINCH" is enforced structurally instead of by agreement — the signal is
asserted at Tier 2, where a signal exists.

The split matters and is deliberate: only the Tier-2 lane carries
`--path:../TermAssert/src --path:../TermAssertClient/src
--path:../nim-libvterm/src`. A Tier-1 suite that could compile against
TermAssert would be one edit away from spawning a pty in the fast lane, and the
separation is what keeps "asserted in process" and "asserted on a terminal"
answerable separately.

`src/frontend/tui/tests/apps/` holds child apps, not tests. They are named
`app_*.nim` so neither lane's discovery collects them; the Tier-2 suites
compile them on demand through `dual_snap.compileChildApp`, which is
timestamp-guarded against the app source, `test_app_runtime.nim` **and every
`.nim` under `app/`** (`dual_snap.newestSourceTime`).

That last clause was added by CTUI-5 after it bit: a mutation arm edited
`app/views/gutter.nim`, rebuilt, ran the Tier-2 suite and restored the file —
and the next lane run reused the MUTATED binary, because neither the app source
nor the runtime had changed. The suite reported a defect that no longer
existed. The dangerous direction is the other one: a cross-tier comparison
between a fresh Tier-1 model and a stale Tier-2 binary is a comparison of two
different programs.

**CTUI-7 met the same trap through a different door, and it is worth knowing
before you run a mutation arm.** The stamp compares MTIMES. Restoring a mutated
file from a backup taken with `cp -p` — or with `git stash`, or with any tool
that preserves timestamps — gives the restored file an mtime OLDER than the
binary built from the mutation, so `newestSourceTime` sees nothing new and the
next Tier-2 run reuses the mutated child app. It presents as three suites
failing on rows whose model and terminal text differ by exactly the thing the
arm changed, long after the arm was restored and `git diff` is clean. The remedy
is two commands:

```sh
find src/frontend/tui/app -name '*.nim' -exec touch {} +
rm -rf test-logs/tui-dual-snap/bin
```

The guard is right; a timestamp-preserving restore is what defeats it. Sibling libraries (`isonim-tui`, `TermAssert`) are
deliberately **not** in the stamp — a child app draws `app/`, and rebuilding on
every sibling edit would cost the lane a link per case for a dependency that
moves far less often.

### Where the artifacts are

```
test-logs/tui-dual-snap/
  bin/                       compiled child apps
  nimcache/                  shared, so the second app costs a link
  cases/<stem>-<W>x<H>/
    tier1/  plaintext.txt ansi.ansi cellmap.json svg.svg annotated.svg treedump.txt
    tier2/  the same six, written by TermAssert
```

Both directories survive the run. On a failure, diff them — and read
`svg.svg` in a browser if the plaintext is not enough. `/test-logs/` is
gitignored, so nothing here can dirty the tree.

---

## Layering: where a test module may live

```
src/frontend/tui/
  app/       SDK-CONSUMER. codetracer_embed, headless_app, isonim, isonim_tui,
             std/* that touch neither a process nor a terminal. Covered by
             ci/test/sdk-facade-boundary.sh through a .sdk-consumer marker.
    layout/  profile selection (pure) and the LayoutNode -> Yoga projection.
    views/   header, status bar, shell — every one a pure function to text.
    tests/   Tier-1 suites that MUST obey the app/ layer rule (see above).
  host/      NATIVE HOST. The only place allowed to reach backend/stdio_backend
             and viewmodel/headless_session (osproc, pty, termios, signals),
             and the owner of SIGWINCH (host/resize.nim). Exempt from the
             facade guard, and the exemption is CHECKED.
  testing/   TEST-ONLY. Needs app/'s capability AND host/'s, and the shipped
             binary links none of it. Not reachable from main.nim — asserted.
  tests/     Tier-1 suites, plus apps/ and real_terminal/.
  main.nim   wires host/ to app/ and nothing else.
```

### The F10 step key

`testing/test_app_runtime.nim` also recognises one INPUT sequence, `\x1b[21~`
— xterm's F10, which is exactly what `TermAssert`'s `sendKey("f10")` writes.
On it the runtime increments a step counter, rebuilds the tree and repaints,
leaving the cursor back on the frame barrier. CTUI-5's Tier-2 test is specified
as "step with `sendKey(\"f10\")`", and a snapshot app therefore has to be able
to advance rather than only to paint.

It is **not a flag** and adds nothing to any command line: `buildTree` gains an
optional `step` parameter (`SteppedTreeBuilder`), and an app that ignores it
paints the same tree however often F10 arrives. Under `--test-ipc` the child
labels step 0 with the parent's own label and step *N* with `<label>-stepN`
(`stepLabel`), so a parent driving F10 asks for the frame it wants BY NAME
rather than by timing.

### Driving a snapshot app with real input (CTUI-6)

`runSnapshotApp` takes two optional callbacks, both `nil` for every CTUI-2,
CTUI-3 and CTUI-5 app — which is why their byte streams are unchanged:

* **`input: proc(token: string): bool`** receives one complete input token — a
  plain byte, or a whole escape sequence — and answers whether to repaint. The
  runtime does the framing (accumulate from `ESC [` to a final byte in
  `0x40..0x7E`), so an app decodes a value instead of running a state machine.
  That is what lets `app/input/call_stack_keys.decodeMouse` be asserted against
  the exact bytes `TermAssert.sendMouseClick` writes, in the Tier-1 lane, with
  no pty.
* **`links: proc(cols, rows: int): seq[PaneHyperlink]`** says where OSC 8
  hyperlinks go on the frame about to be painted. isonim-tui has no hyperlink
  concept at all, so `app/views/hyperlinks.frameBytesWithHyperlinks` emits them
  **inline with the frame**, walking the same buffer in the same order as
  `encodeAnsi`. With no links its output is byte-identical to `frameBytes`, and
  `tests/real_terminal/test_real_call_stack.nim` asserts exactly that.

**An input-driven repaint increments the step counter**, so the new frame has a
name. This is not cosmetic: `waitForCompleteFrame` cannot be the barrier after
an input, because the cursor is *already* parked on the bottom-right cell from
the previous frame and the call returns immediately. A parent that drove a click
and then read the screen would read the frame from before its own click. The
child labels the repaint `<label>-stepN` and the parent waits for that label.

> **Rule: after sending input to a child, wait for a frame you can NAME.** The
> cursor barrier proves *a* frame is complete, never that *your* frame is.

### Driving a snapshot app with real KEYS (CTUI-9)

CTUI-9 made three changes to `testing/test_app_runtime.nim`, all of them
additive, and each one closes a hole that made a §4.2 binding untestable at
Tier 2. Know them before you write a key-driven case.

* **F10 now reaches the app.** CTUI-5 made `\x1b[21~` the runtime's own step
  key, which meant the one function key §4.2 binds — "Step Over (Forward)":
  `n` / `F10` — was the one key no app could be asked about. The token is now
  offered to `input` *before* the step, and the step still happens, so every
  CTUI-2/3/5/6/8 app behaves exactly as it did.

* **`ISIG` is cleared in `enterRawMode`.** §4.2 binds `Ctrl+c` to "Quit
  Debugger — Exit CodeTracer TUI session **cleanly**". With `ISIG` set the line
  discipline turns `0x03` into `SIGINT` before the application reads a byte:
  the child dies on the signal and `sendControl('c')` measures the tty rather
  than the keymap. Clearing it is what `cfmakeraw(3)` does. No existing app is
  affected — none is sent `0x03`.

* **`FramePrologue`**, bytes written immediately *before* a frame. It exists
  for the cursor: §4.1's modes are told apart on a real terminal by DECSCUSR
  shape and DECTCEM visibility (`app/input/modal_state.cursorControlBytes`),
  and "the model has no cursor" is a row of the table above. `nil` for every
  app that does not want it, and with it the byte stream is unchanged.

**Two more bytes never reach the app, and F10 was only the third.** `q` is
`TestAppQuitByte` and `0x04` ends the child too, so the keybinding table's `q`
("Quit Debugger") and `Ctrl+d` ("Half Page Down") cannot be driven at Tier 2 —
sending either ends the process instead of pressing a key. `Ctrl+c` is the
quit binding that *is* exercised here, and its half-page twin `Ctrl+u` (`0x15`)
is unaffected. Assert those two at Tier 1, and do not read a green Tier-2 case
that sends `q` as evidence that anything was bound.

**A lone `Esc` cannot be delivered as one byte.** The runtime accumulates from
`\x1b` while the buffer is still a prefix of the F10 sequence, so a single
`\x1b` sits there until something else arrives. Send `\x1b\x1b`: the second one
breaks the prefix, is not a CSI, and falls through the "honour the byte that
broke the prefix" arm — delivering exactly one `Esc` token.
`tests/real_terminal/test_real_keybindings.nim` asserts the MODE that produces,
so a change to the framing reddens rather than silently delivering nothing.

**`TermAssert.sendKey` drops `shift+`.** Its modifier loop consumes the prefix
without recording it, so `sendKey("shift+f10")` writes `ESC [ 2 1 ~` — byte for
byte what `sendKey("f10")` writes. To exercise a shifted function key, write
xterm's modified sequence yourself: `ESC [ 2 1 ; 2 ~` (the parameter is
`1 + Shift`). CTUI-9 drives both and asserts the consequence of each, rather
than working around the harness silently.

### Parking the cursor somewhere else (CTUI-10)

CTUI-10 added one more additive hook to `testing/test_app_runtime.nim`, and it
is the only one that **moves the cursor**.

* **`FrameEpilogue`**, bytes written immediately *after* a frame. It exists for
  §3.3.6's prompt: a `:` prompt is a prompt only if the terminal's own cursor is
  sitting in it, and "cursor position" is a row of the table above. `nil` for
  every CTUI-2 through CTUI-9 app, and with it the byte stream is unchanged for
  all of them — the cross-tier suite is what keeps that true.

> **An app that installs a `FrameEpilogue` breaks `waitForCompleteFrame`.**
> The barrier is "the cursor rests at `(rows-1, cols-1)`", and an epilogue that
> moves it means that can never be satisfied. Wait on
> `dual_snap.waitForCursorAt(row, col)` instead: the same barrier argument at
> the position the epilogue parks on, and equally exact, because the CUP is
> written after the last cell of the last row. `apps/app_command_mode.nim`
> returns `""` from its epilogue whenever no prompt is open, so its NORMAL
> frames still use the ordinary barrier and only its prompt frames need the
> other one.

### Driving the SHIPPED BINARY on a real trace (CTUI-11)

Until CTUI-11 every Tier-2 case spawned a **snapshot app**: one component tree,
`test_app_runtime`'s runtime, no debugger. CTUI-11 gave `main.nim` a driver, so
`build/bin/codetracer-tui <trace-folder>` is now itself a subject —
`tests/real_terminal/test_real_capability_negotiation.nim` spawns it. Three
things about it differ from a snapshot app and all three will bite.

**It paints TWICE on startup, and `waitForCompleteFrame` returns on the first.**
`main.nim` negotiates the terminal, claims the tty and paints *frame 0* — the
shell, with `opening <folder> …` on the status line — and only then spawns
`replay-server`. Frame 1 is the debugger. Both end with the cursor on the
bottom-right cell, so the cursor barrier cannot tell them apart. Wait for the
status row to stop saying `opening ` and *then* for the cursor barrier;
`settleOnDebugger` in that suite is the shape.

That order is deliberate and is not a testing convenience: a front-end that
showed nothing until the engine answered would be indistinguishable, for that
whole second, from one that had hung. It is also what makes CTUI-11's cold-start
gate measurable — process start to frame 0, with probing enabled, measured at
**25 ms** on a 24-core host at load 10.8.

**It needs a real recording.** `resolveFixture("calc")` from
`tests/fixtures/fixture_provider.nim`, and a resolution failure **fails by
name** with the recipe rather than skipping.

**It restores the terminal on the way out**, so anything read after the child
exits reads a terminal that has been given back: `mouseProtocol()` is `mpNone`
again after `?1006l ?1000l`. Read the negotiation **while the child is alive**.

### What libvterm can and cannot see about DEC 2026

`synchronizedOutput()` is a **live flag, not a latch**:
`nim-libvterm/extended_state.handleCsi` sets it on `CSI ? 2026 h` and clears it
on `CSI ? 2026 l`. After a complete frame it reads `false` whether the driver
bracketed correctly or never opened a bracket at all.

**`TermAssert.assertSynchronizedRender` cannot fail.** Its "not observed" arm is
`discard` (`TermAssert/src/term_assert.nim:640-647`). Calling it satisfies the
published gate and asserts nothing, so it is never the only thing a case does.

The pairing is therefore established in two halves, both falsifiable:

* feed `host/terminal_driver.bracketFrame`'s own output into a fresh
  `nim_libvterm.newScreen` — the same parser the pty path uses. The flag goes
  **true** after the open and **false** after the close, and a stream missing the
  close leaves it **true**. That is the positive control, and the mutation arm
  is one line.
* assert `synchronizedOutput() == false` on the live binary after a settled
  frame. An unpaired open latches it and reddens this.

### The token framer is `host/`'s now, and the snapshot runtime consumes it

`testing/test_app_runtime.nim` no longer carries its own byte-to-token state
machine, timed read or `frameBytes`. All three moved to
`host/terminal_driver.nim` and it imports them. The direction is forced:
`tests/test_tui_build_prerequisites.nim` asserts that no module under `testing/`
is in `main.nim`'s import closure, so the shipped driver cannot import the
runtime.

Behaviour is byte-for-byte what it was on every sequence any suite here sends,
including the two documented above (a held lone `\x1b`, and `\x1b\x1b`
delivering exactly one `Esc`). **One thing was added: SS3.** `ESC O P` … `ESC O
S` are xterm's F1-F4 and exactly what `sendKey("f1")` writes; the old framing
dropped the `ESC` and delivered `O` then `P` as two ordinary bytes, so §4.2's
`F1` (Command Palette) was a binding no terminal could reach. Nothing in this
tree sent those bytes, so no existing byte stream moved.

**What was NOT shared is the termios.** `host/terminal_driver.start` uses
`nim-termctl`'s `enableRawMode`, which installs the signal-safe restore CTUI-11
asks for — and with it an `atexit` hook that writes an alt-screen leave, a
mouse-off and a cursor-show as the process dies. A snapshot app must not do
that: those bytes would land on the pty a suite is still parsing, and
`cursorVisible` is a fact CTUI-9's modal cases assert.

### An empty shell has no styled spans on it

Measured while writing `app/tests/test_degraded_style_tables.nim`:
`newShellModel(...)` plus `shellStyledRows` produces a screen with **zero**
cells carrying a colour. `app/views/shell.paintPane` draws CTUI-3's plain
`TITLE ────` row with the default style and only delegates to a pane's own
painter when that pane's model has content.

So a fixture built from `newShellModel` alone makes "no colour after degrading"
true for free, on a screen that never had any — the positive-floor trap arriving
through a fixture instead of through an assertion. Fill at least one pane model
(`initTimelineBarModel(boundsKnown = true)` is the cheapest) before asserting
anything about styles.

### `unicode.strip` does not strip an all-whitespace string

A Tier-2 suite that reads rows off the terminal almost always trims the
right-hand padding, and almost always imports `std/unicode` for `Rune`. Those
two facts collide:

```nim
import std/[strutils, unicode]
let blank = repeat(' ', 10)
blank.strip(leading = false)            # ten spaces — unicode.strip wins the overload
strutils.strip(blank, leading = false)  # ""
```

Measured on nim 2.2.8. `unicode.strip` returns an **all**-whitespace string
unchanged; `strutils.strip` returns `""`. Every assertion about a row *with
content* passes either way, so this only ever shows up as "a blank row is 100
characters long" — which is how it was found, in
`tests/real_terminal/test_real_command_mode.nim`. **Qualify `strutils.strip` in
any helper that reads a terminal row.**

### Test-only flags on the snapshot runtime

`testing/test_app_runtime.nim` parses three flags no shipped binary may know:
`--test-ipc` (CTUI-2), `--never-settle` (CTUI-2) and `--reflow` (CTUI-3).
`--reflow` is what installs `host/resize.nim`'s SIGWINCH watcher in a child
app, takes the geometry from `ioctl(TIOCGWINSZ)` rather than from `--cols` /
`--rows`, and repaints on a kernel-delivered resize. All three are asserted to
be **refused by `app/cli.parseTuiCommand`, absent from `TuiHelpText`, and
unreachable from `main.nim`'s import closure** in
`tests/test_tui_build_prerequisites.nim`.

`tests/test_tui_facade_boundary.nim` walks `app/`'s import graph structurally —
imports resolved to files, with seven mutation arms — and
`tests/test_tui_build_prerequisites.nim` walks `main.nim`'s closure to keep
`testing/` out of it. Neither is a source grep; both resolve.
