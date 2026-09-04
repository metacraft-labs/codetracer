# Self-hosted macOS runner defects — the register

These runners are **persistent**. Their home directory, work directory, git
config, nix store and background daemons survive between jobs, so a defect one
job leaves behind is inherited by whatever runs next — usually a different job,
often a different repository. That is what makes this class expensive: **the job
that fails is almost never the job at fault**, and the message it fails with
tends to name neither.

This file exists because the list below lived only in one person's head. Seven
defects were diagnosed over one campaign; the count was reported as five twice
before being reconciled upward. A register that is not in the tree gets
recounted from memory, and memory rounds down.

## Rules this list is maintained by

- **A fix needs a gate that was proved able to fail.** Not re-read — *run*
  against the broken input, and seen to name what it found. Two checks in this
  campaign's history could only ever pass: a `*.lock` sweep whose first version
  matched anywhere (it was deleting `Cargo.lock`, `flake.lock`, `repro.lock` and
  `yarn.lock` from sibling checkouts — a sweep meant to unblock checkout was
  quietly unpinning the build), and a credential recount that `494d85395`
  records as "itself a no-op".
- **Never weaken a check to make it green, and never edit an expected count
  down.** Several corrections here went *up*.
- **Prefer planting the failure to arguing about the code.** Where a gate below
  has a contract suite, the negative case is the real pre-fix file read out of
  `origin/dev` rather than a mock of it.
- **A partial fix is recorded as partial.** Two entries below are mitigations
  whose root cause is still unidentified or unaddressed; saying so is the point
  of the entry.

---

## 1. The `repro` daemon never `chdir`s — CLOSED here, cause still upstream

**Symptom.** Any `repro build` on the runner dies with:

```
daemon-hosted build failed: No such file or directory
```

naming no path and no owner.

**Cause.** The `repro` user daemon is persistent and its endpoint is
deliberately stable across `nix develop` sessions, so one daemon serves every
job on a runner indefinitely. On macOS it is started via launchd, and when that
fails it falls back to a plain fork+setsid: `launchWithFork` in reprobuild's
`libs/repro_daemon_core/src/repro_daemon_core/runtime.nim` calls `setsid()` and
then `execve` **with no `chdir` between them**. `chdir` and `setCurrentDir`
appear nowhere in that library, and no launchd plist written here sets
`WorkingDirectory`. The daemon therefore inherits — and keeps — the working
directory of whichever `repro build` first spawned it. Once that directory is
gone (a re-cloned workspace, a deleted temp root), every later build dies in the
first statement of the daemon-side build executor, `getCurrentDir()`.

**State.** `a556399c0` diagnosed this and named two victims,
`reprobuild-macos-smoke` and `test-ui-tests (macos)`, but guarded only the
first. `ci/reprobuild/macos-daemon-build.sh` — the script that *deliberately*
runs `repro build --daemon=auto`, and so the likeliest thing on a runner to
leave a daemon behind — had no `repro daemon stop` anywhere, including its trap.
It now stops the daemon before building and on every exit path.

A second defect surfaced while fixing the first: that script's only
`trap ... EXIT` was armed **inside** `start_runquotad`, which returns early when
`RUNQUOTA_SOCKET` is already set. On that path the script had no exit handler at
all, so it leaked `runquotad` and its socket directory too. `trap` replaces
rather than composes; the handler is now armed once, at top level.

**Gate.** `ci/verdict/reprobuild-daemon-guard.sh`, suite
`ci/test/reprobuild-daemon-guard-test.sh` (9 assertions, in the bash lint lane).
It requires a stop before the first build, exactly one EXIT trap armed at top
level, and a stop inside the handler that trap names. Comments are stripped
before matching — these scripts discuss `repro daemon stop` at length, and a
checker satisfied by its own explanation is the defect it was written against.
It refuses to pass on an empty directory.

**STILL OPEN, upstream.** The durable fix is one line in another repo: perform
`chdir("/")` in the fork path, and let the daemon tolerate a vanished cwd.
Until then codetracer only stops being both cause and victim of its own jobs;
any other product's `repro build` on these runners can still poison them.

---

## 2. Stale git `extraheader` credential → HTTP 401 — MITIGATION, NOT A CURE

**Symptom.** `actions/checkout` fails to authenticate; git reports
`could not read Username`, which is a 401 in disguise.

**Cause.** A stale `http.<url>.extraHeader` in `$HOME/.gitconfig` carrying a dead
token. Git resolves `http.<url>.*` by **longest matching prefix**, so a narrower
stale entry outranks the fresh, correctly-scoped one that checkout installs.

**State.** An inline pre-checkout sweep,
`Evict stale git credentials from this runner's persistent home`, duplicated
across **8 jobs** in `.github/workflows/codetracer.yml` — lines 1802, 2034, 2236,
3569, 4094, 4651 (canonical copy, carries the full rationale), 5212 and 6085. It
must run *before* `actions/checkout`, so it cannot be a script this repository
provides. It matches only `http.*.extraheader`, `http.*.extraHeader` and
`url.*x-access-token*`, operates on `$HOME/.gitconfig` **by path** (not
`--global`, because XDG can redirect that), and recounts in pure bash — `grep`
and `sed` are not on a raw `run:` step's PATH on these nix-darwin runners.

Introduced by `083aa0c23`.

**STILL OPEN.** The step's own comment
(`.github/workflows/codetracer.yml:4698-4706`) says so:

> STILL UNKNOWN: WHO WRITES IT. `configure-git-auth.sh` in
> metacraft-labs/metacraft-github-actions installs exactly this key but
> deliberately passes it through `$GITHUB_ENV`, which is job-scoped, so on its
> documented path nothing should reach this file. Something on these runners
> writes it anyway (mcl-004's copy was stamped 08:15 on the day of the outage).
> Until that writer is found this step is a mitigation, not a cure — it runs
> before every checkout precisely because the poison can come back.

Finding the writer is the open work. Note also that the sweep asserts a
**non-zero** count on a poisoned host rather than merely a zero afterwards —
that distinction is what `494d85395` was about.

---

## 3. Stale `*.lock` sentinels blocking checkout — CLOSED

**Cause.** Git metadata locks (`index.lock` and friends) left by a killed job
make the next checkout fail.

**State.** `Sweep stale git lock files from the persistent work directory`,
`.github/workflows/codetracer.yml:5981`, in `visual-replay-regression-gate` —
the only persistent `[self-hosted, gpu]` job, hence the only copy.

**Read this before touching the pattern.** The first version matched
`-name '*.lock'` anywhere under the work directory and, measured on run
33734457928, deleted 42 files including `codetracer-trace-format/Cargo.lock`,
`flake.lock`, `nim-agents/repro.lock` and
`isonim/src/isonim/layout/yoga/yarn.lock`. A sweep meant to unblock checkout was
quietly unpinning the build. The current pattern is anchored:

```sh
find "$root" -type d -name .git -exec find {} -type f -name '*.lock' -mmin +60 ';'
```

The outer `find` restricts to directories literally named `.git`, so no
lockfile in a worktree is reachable; `-mmin +60` protects locks held by a
concurrent job. Both constraints are load-bearing — **do not flatten this into a
single `find`.**

Fixed by `083aa0c23`, anchored by `444cfa989`.

---

## 4. Read-only `.app` leftovers make runners uncleanable — CLOSED

**Cause.** A Nix-store-mode `.app` bundle is copied out read-only; the next
job's checkout cannot delete it.

**State.** `ci/runner/sweep-readonly-leftovers.sh`, plus a `chmod -R u+w`
remediation at `.github/workflows/codetracer.yml:6068-6083`. Fixed at the source
(the bundle is made writable when produced) *and* swept where already poisoned.
Landed in `444cfa989`.

**Gate.** `ci/test/readonly-leftovers-sweep-test.sh`, in the bash lint lane. It
asserts a **non-zero** count on a poisoned fixture, not merely a zero
afterwards.

---

## 5 & 6. `/usr/bin` missing from a raw `run:` step's PATH → exit 127 — CLOSED per site, STRUCTURALLY OPEN

These were logged as two defects and are one root cause, which is why they kept
recurring under new names.

**Cause.** `nix develop` prepends store paths and keeps the ambient PATH as the
tail. On these nix-darwin runners a raw `run:` step's ambient PATH has no
`/usr/bin`, so any Apple system tool is simply absent — exit 127, "command not
found", for a binary that is obviously installed.

**Victims, in the order they were found:** `codesign`, then `sw_vers` (via
`create-dmg`), then `hdiutil`. Each was fixed where it bit:

| Site | Fix | Commit |
|---|---|---|
| `codetracer.yml:5516` (`test-ui-tests`, ct-mcr) | `PATH="$PATH:/usr/bin"` | `3ac64e9f2` |
| `codetracer.yml:3727` (`dmg-build`) | `PATH="$PATH:/usr/bin:/usr/sbin"` | `5f6ab33ce` |
| `codetracer.yml:4252` (`dmg-lib-check`) | `PATH="$PATH:/usr/bin"` | `bf7bfd54d` |
| `codetracer.yml:5590` (`test-ui-tests`, build-once) | `PATH="$PATH:/usr/bin"` | `bed00876f` |

**Append, never prepend** — the devShell toolchain must keep winning; the point
is only to make the system tools reachable in the tail.

The last entry is the widest: `repro` passes PATH through to all 42 actions
(`0 hermetic, 22 inherited`), so the `dmg` action inherits whatever deficiency
the invoking step had.

**STILL OPEN, structurally.** Four independent point fixes for one root cause,
and the comment at `codetracer.yml:5573-5574` already records the second as "the
second confirmed instance of that one root cause". There is no runner-level or
workflow-level `env: PATH` fix, so a fifth site will fail the same way. A
workflow-level default, or a lane guard asserting `/usr/bin` is on PATH in every
raw `run:` step that invokes a system tool, would close the class rather than
the instance.

---

## 7. Recorder siblings cloned but never built — CLOSED

**Symptom, ruby.** A `require` failure from inside
`CodeTracer::Native.load_extension!`, naming a `.so`/`.bundle` the reader has
never seen.
**Symptom, js.** `codetracer-js-recorder is not built (…/packages/cli/dist/index.js)`
from `scripts/materialize-recording.sh`, repeated for every recording the
Playwright suite materialises — an hour into the run.

**Cause.** `grep -E 'rake compile|extconf|build-extension'` over `.github/`
returned **zero** hits. The ruby extension was built only by
`scripts/build-siblings.sh`, reached solely by the **Linux** `ct-test-providers`
job, while `test-non-gui` and `test-ui-tests` cloned the recorder on macOS and
ran against a tree with no compiled artefact. Separately, the fix for
"`test-ui-tests` never cloned `codetracer-js-recorder`" (`8616ff406`) added the
clone but no build — `npm run build` existed in this repository only inside that
step's own comment.

**Why it was silent rather than loud — the dominant defect of this campaign.**
`scripts/detect-siblings.sh` probed
`gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder`, a nine-line shim
**checked into git at mode 100755**. Present in every fresh clone, so the test
could not fail, detection printed `(native)` unconditionally, and the "not
built" warning beside it was unreachable code. The python recorder had the same
shape: it keyed off the source directory and a venv interpreter, neither of
which says the maturin/pyo3 extension was ever installed.

> **A detector that probes the wrong artefact does not merely fail to help — it
> actively converts a build error into a runtime mystery.** When adding a
> recorder, probe the file its *loader* opens, and check the probe against the
> loader's own resolution order.

**State.** Both probes now track the compiled artefact and resolve the platform
DLEXT (`.bundle` on macOS — `.so` is the Linux spelling and was wrong on every
Mac). `test-non-gui` and `test-ui-tests` build the ruby extension; `test-ui-tests`
builds the JS recorder. Both new steps assert the **artefact**, not the exit
code. `scripts/build-siblings.sh`'s hard-coded `.so` was made platform-aware,
since otherwise a green macOS build reports its own artefact missing.

**Python needs no workflow build step** — `nix/shells/main.nix`'s hook installs
the recorder into `.python-recorder-venv` on every `nix develop`, and writes
`.broken` (which `scripts/test-python-version-alignment.sh` fails on) when it
cannot. Asserting one would be a false failure. Checked, not assumed.

**Gates.** `ci/test/detect-siblings-recorder-artifacts-test.sh` (13 assertions)
and `ci/verdict/recorder-clone-implies-build.py` with
`ci/test/recorder-clone-implies-build-test.sh` (12 assertions), both in the bash
lint lane. Every "must warn" is paired with a "must not warn", because a probe
that only ever says one thing is the defect whichever thing it says.

The second gate follows `just` targets into the `Justfile`: `viewmodel-tests`
builds the JS recorder via `just test-vm-recorder-gated` →
`build-siblings.sh --only`, and the checker's first version called that a
violation. The rule was **not** relaxed to permit it — the checker was taught to
see it. A false positive trains the reader to skip the check, which costs
exactly what a missing check costs.

**Known remaining gap, not yet reached.** The nixos leg's `siblings:` block does
not carry the JS recorder either; that leg currently fails earlier, in the
storybook build, so the gap has never been exercised.

---

## Scoreboard

| # | Defect | State |
|---|---|---|
| 1 | repro daemon never `chdir`s | codetracer guarded; **cause open upstream** |
| 2 | stale `extraheader` → 401 | **open** — mitigation, writer unidentified |
| 3 | stale `*.lock` sentinels | closed |
| 4 | read-only `.app` leftovers | closed |
| 5 | `codesign` 127 | closed per site |
| 6 | `create-dmg`/`sw_vers`/`hdiutil` 127 | closed per site; **class open** |
| 7 | recorder cloned, never built | closed |

Four closed, three carrying open work — 1 upstream, 2 entirely, and 5/6 as a
class. Update this table in the same commit as the fix, not afterwards.
