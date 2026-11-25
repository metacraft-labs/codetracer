
### Setup

### Set up the container options


* Eventually we needed to set up the lxd container as privileged to make it possible to run the `aufs` driver for docker
* Also it seems we need to do this https://stackoverflow.com/questions/46645910/docker-rootfs-linux-go-permission-denied-when-mounting-proc/46648124#46648124 to be able to change system limits for rr and codetracer

### Install docker

* Install docker from their apt repository:
  * Running commands from https://docs.docker.com/engine/install/ubuntu/ -> https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository

We use those commands:

```bash
sudo apt-get remove docker docker-engine docker.io containerd runc

sudo apt-get update

sudo apt-get install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

sudo apt-get install -y docker-ce docker-ce-cli containerd.io # original command doesn't pass -y: sudo apt-get install -y docker-ce docker-ce-cli containerd.io
```

### Install `gitlab-runner`

* Install gitlab-runner from their apt repository:
  * Running commands from https://docs.gitlab.com/runner/install/linux-repository.html#installing-gitlab-runner

```bash
# needs sudo!
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash

sudo apt-get install -y gitlab-runner # original command doesn't pass -y : sudo apt-get install gitlab-runner
```

### Build `codetracer_base` docker image

* Copy `build` folder from a codetracer repo to the server:

```bash
scp -r build codetracer-hetzner:/home/codetracer/build
```

* `codetracer-hetzner` is in my ssh config file as a host section: you might need to replace it
* `rsync` might be a faster way to copy files, but `build` is a small folder. TODO: do we need to document usage of rsync?

* Make the image

```bash
sudo docker build -t codetracer_base .
```

### Configure linux limits/settings for rr/codetracer

* Enough file watches

```bash
echo fs.inotify.max_user_watches=700000 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p;
```

* Enable `perf_event_paranoid=1`

```bash
echo kernel.perf_event_paranoid=1 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
```

### Configure `gitlab-runner`: copy `config.toml`

* Copy `config.toml` file from a codetracer repo to the server:

Locally:

```bash
scp config.toml codetracer-hetzner:/home/codetracer/config.toml
```

On server:
```bash
sudo cp /home/codetracer/config.toml /etc/gitlab-runner/config.toml
```

* `codetracer-hetzner` is in my ssh config file as a host section: you might need to replace it (see notes for building codetracer_base docker image: copying `build`)

* You can also use `gitlab-runner register` to dynamically fill such a section

* You might need to change docker volumes in config.toml

## Configuring GitLab runners: in the GitLab runners web interface and command line/config.toml

* You might need to get new or custom runner token from our/your gitlab repo's runner web interface:
  * Visit your repo's web interface
  * `Settings` > `CI/CD` > `Runners` > `Specific Runners`
  * It seems the url for our repo might be <https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/runners#js-runners-settings> or
      <https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/settings/ci_cd>
* Use the token and run on the server

```bash
export GITLAB_RUNNER_TOKEN=<insert token>

sudo gitlab-runner register \
  --non-interactive \
  --url https://gitlab.com \
  --registration-token $GITLAB_RUNNER_TOKEN \
  --executor docker \
  --docker-image codetracer_base:latest \
  --paused
# maybe remove the token or just use it directly in the command
```

* Copy the new added by gitlab token from /etc/gitlab-runner/config.toml and replace it in our copy from the repo's config.toml
* Copy this fixed version of the repo config.toml to /etc/gitlab-runner/config.toml
* Run `sudo gitlab-runner restart` (not sure if always required)
* Check for a new runner in the gitlab runners interface
* Make sure the setting for the runner's flag `Can run untagged jobs` is `Yes` in the gitlab runners interface
* Unpause the runner

(This GitLab token setup workflow was based on https://stackoverflow.com/questions/54658359/how-do-i-register-reregister-a-gitlab-runner-using-a-pre-made-config-toml)

* If other changes were needed in the repo config.toml file, change it and commit it

* To test: push a commit to the gitlab repo or start a job manually from gitlab web interface

### Notes

I use `fish`, so I install it with `sudo apt install fish`. Keep in mind some of those comm ands use syntax that requires `bash`.


## GitHub Actions scheduling

### Windows subprocess tool selection

Windows build and test subprocesses must use the tools selected by the activated
development environment. Rust callers resolve Bash from that environment's PATH
in order and pass its absolute executable path to `Command`; relative and empty
PATH entries are resolved against the current directory. A missing Bash is a
missing prerequisite, not permission to fall back to Windows system search.

CI must not take ownership of, change permissions on, delete or hide operating
system executables to influence tool selection. It must not substitute a
hardcoded Git installation for the declared Bash provider. Script argument path
conversion is separate from executable selection.

The normal pre-commit shell runs the unchanged Rust hooks using the backend
package's same declared compiler and tools, Nix-native mode flags and immutable
Nim dependency paths. It does not require the unrelated full development SDK.


The executable triggers and concurrency expressions remain in
[the CodeTracer workflow](../.github/workflows/codetracer.yml). The rationale
below was moved from that file at `b2603929` to keep it below GitHub Actions'
500 KB workflow limit. Its numbered line references describe that historical
workflow; the scheduling expressions and all jobs remain unchanged.

WHY `cloud` IS ON THIS LIST.

`cloud` is the web branch, and until this entry existed the ONLY
workflow a push to it triggered was `deploy-web-codetracer.yml`. That
workflow builds the Embed SDK bundle and ships it to Cloudflare Pages.
It runs no test lane at all -- not `vm-native`, not `vm-js`, not the
known-failure ledger, not the lane-coverage guard, not the
dap-command-sync guard. So everything landing on `cloud` was verified by
local runs only, and a green deploy corroborated none of it: it says the
bundle built, which is a strictly weaker claim than the one a reader
takes from a green check next to a commit.

The sharpest form of the problem was that THREE OF THOSE GUARDS LIVE
ONLY ON THIS BRANCH. `cloud` carries 64 lines of this file that `dev`
does not -- "The web bundle mounts a product", "A registered known
failure signals when it goes green", "One press, one action; one pane
id, one node". They were added here, they are not on `dev`, and with no
trigger on `cloud` they could not run anywhere at all. A guard that
cannot run is a comment.

WHY NOT THE ALTERNATIVES. Merging `cloud` into `dev` regularly would let
the lanes see the code, but only after it landed, and only for as long
as somebody kept doing it -- verification that depends on a habit is the
thing this workflow exists to replace, and it would still leave `cloud`
itself unverified between merges. Accepting the gap deliberately was the
honest third option and is what was in force by default; it is not worth
keeping now that the guards intended to run here are sitting here unrun.

THE COST IS REAL AND IS PAID FOR BELOW. `cloud` deploys on every push,
so it is pushed often and in bursts, and this is the widest workflow in
the repository. Adding it here means every one of those pushes now also
starts a full three-platform matrix. The `concurrency` block is what
makes that affordable: unlike `main`/`dev`/`stable`, a superseded
`cloud` run is cancelled, so a burst of five pushes leaves one live run
rather than five. See the note there for why the mainline branches must
NOT be treated that way.

PERIODIC COVERAGE ON `dev`, WHICH PUSH RUNS NO LONGER PROVIDE.

Measured on 2026-09-03: THIRTEEN consecutive `dev` runs (1a427e3e
through a3068f90) ended `cancelled` with ZERO job records ever created,
and `dev` had produced no `lint-bash` result -- of any kind -- for 22
commits. The runs did not fail; they never started.

The mechanism is the `concurrency` block below, and the timings name it
exactly: each run's `updated_at` equals the NEXT run's `created_at`.

    aedc094c  created 13:05:43  updated 13:11:18
    54e88f92  created 13:11:16  updated 13:12:29
    2880155b  created 13:12:27  updated 13:19:01
    141293d6  created 13:19:00  updated 15:09:08

`cancel-in-progress: false` protects a run that has STARTED. On a fleet
where jobs wait hours for a runner, a mainline run never starts before
the next push arrives, so it is evicted as the single PENDING run its
group is allowed. The block's own rationale assumes "a burst of twenty
pushes leaves one running plus one pending"; what it actually leaves is
ZERO running and one pending, and that one is evicted too. The premise
is right about drainage and wrong about coverage.

WHY NOT JUST REVERT THE GROUPING. Per-commit coverage and a short queue
cannot both hold on a saturated fleet. `github.run_id` grouping buys the
first at the cost of an unbounded queue -- the state that produced 46
pending runs whose survivors were eight hours old -- and a queue that
deep does not deliver coverage either, because it never reaches most of
its entries. A PERIODIC run on the current tip gets the part that
matters (a real verdict on `dev`, regularly) without the queue growing,
because it fires on a clock rather than per push.

WHY `workflow_dispatch` AND NOT `schedule:` HERE. A `schedule:` trigger
fires ONLY on the repository's default branch, using THAT branch's copy
of this file. This repo's default branch is `stable`
(`gh api repos/metacraft-labs/codetracer --jq .default_branch`), not
`dev` -- so a `schedule:` entry added here would give `stable` periodic
coverage and `dev` none, which is the opposite of the problem. Dispatch
is the trigger that can target `dev`'s tip and run `dev`'s copy of this
file. The recurring clock is a companion workflow on the default branch;
see .github/workflows/dev-coverage-schedule.yml.

NOTE: this also activates `origin-dap-macos-nightly` and
`origin-dap-windows-nightly`, whose `if:` already names
`workflow_dispatch`. That is what they were written for; they have never
run. Neither is in ci/verdict/required-jobs.txt, so neither can corrupt
the verdict this run exists to produce.

Collapse superseded runs. READ THE NEXT SENTENCE BEFORE THE REST: the two
halves of this block collapse DIFFERENT things, and a headline that says
"collapse superseded runs on pull requests AND on the mainline branches" --
which is what this line used to say -- reads as though mainline runs get
cancelled. They do not. On a push, `cancel-in-progress` on line 182 evaluates
to FALSE. What mainline gets is only GitHub's own one-pending-run-per-group
rule, which evicts a QUEUED run and never a STARTED one. On a pull request,
and only there, a started run is cancelled too.

This is the widest workflow in the repository -- Windows, Linux and macOS
legs across three runner classes -- so a superseded run is the single most
expensive thing the fleet can be doing.

WHAT THIS REPLACED, AND WHY THE OLD REASONING STOPPED HOLDING. Until now
pushes to `main`/`dev`/`stable` fell through to `github.run_id`, which is
unique per run, so every mainline commit got a group of its own and nothing
ever superseded anything. The stated reason was bisect fidelity: `dev` is the
integration branch, each commit's build result is independently meaningful,
and collapsing mainline pushes would "destroy history rather than save
capacity".

That argument assumes the per-commit results actually get produced. They had
stopped being produced. With several agents landing on `dev` continuously the
queue reached 46 runs deep against a runner pool that drains far slower, with
in-progress runs roughly EIGHT HOURS old -- so by the time any given commit's
run started, the tip had moved on by twenty-odd commits and the result landed
too late to gate anything. Ungrouped mainline pushes do not preserve history
under saturation; they guarantee the queue grows without bound and NO commit
gets a timely result. The bisect signal was already lost. What the old
configuration actually bought was latency, not history.

THE GROUP. `github.head_ref` is set on `pull_request` and empty everywhere
else, so PR runs still group per source branch -- byte-identical group
strings to before, since `||` short-circuits on the non-empty `head_ref`.
Pushes now fall through to `github.ref_name`, the branch name, so all pushes
to one branch share a group. Note this SUBSUMES the previous special case:
`(github.ref_name == 'cloud' && 'cloud')` was only ever spelling out
`github.ref_name` for one branch, so `cloud` keeps exactly the grouping it
had, for exactly the reason it had it -- it is a deploy branch, what matters
is whether the tip is good, and `deploy-web-codetracer.yml` groups it the
same way.

WHY `cancel-in-progress` IS AN EXPRESSION AND NOT A CONSTANT. This is the
subtle half, and a flat `true` or a flat `false` is wrong in a different
direction each.

GitHub permits only ONE PENDING run per concurrency group regardless of this
setting: queueing a newer run cancels the older PENDING one on its own. So
for mainline pushes `false` already delivers all the drainage -- a burst of
twenty pushes to `dev` leaves one running plus one pending -- WITHOUT killing
a run that has already started. Killing those is actively harmful here: an
eight-hour in-progress run is the one thing in the queue about to yield a
result, and cancelling a run that holds a self-hosted runner strands that
runner offline for ~5 minutes while it is reaped, manufacturing the very
starvation this block exists to relieve. Hence `false` on push.

But `true` must be KEPT for pull requests, and that is a change from what a
naive flat `false` would do. A PR run superseded by a new push to the same PR
is worthless the instant it is superseded -- nobody reads it, the merge
button does not wait on it -- and per the note above it is the most expensive
thing the fleet can be doing. Dropping PR cancellation to `false` would hand
back a large slice of the capacity this change is trying to reclaim. So the
PR path is preserved EXACTLY as it was today: same group, same cancellation.

`cancel-in-progress` accepts an expression, so both live in one block.

KEPT IN STEP WITH `launcher-recorder-e2e-desktop-edge.yml`. That caller fires
on the same push and pull-request edges as this workflow and carries a
byte-identical `concurrency` block. If you retune the group or the
cancellation expression here, retune it there too -- the two were the first
and second largest contributors to the queue backlog, and fixing one alone
leaves the fleet paying for the other.
PERIODIC COVERAGE RUNS GET A GROUP OF THEIR OWN, AND THIS IS THE WHOLE POINT.

The group below is a revolving door: it admits one pending run and evicts it
the moment the next push lands (see the measurements in the
`workflow_dispatch` note above). A coverage run placed in that same group
would be evicted by the very next push exactly like every other `dev` run,
and would be the same failure wearing a different trigger.

So `schedule` and `workflow_dispatch` runs are keyed on `coverage-<ref>`,
which no push or pull request can ever produce: a push falls through to
`github.ref_name` (`dev`) and a PR to `github.head_ref`, neither of which
carries the `coverage-` prefix. A push therefore cannot evict a coverage run,
and a coverage run cannot evict a push -- the two no longer contend at all.

`cancel-in-progress` needs no change: it is already an expression that is
true ONLY for `pull_request`, so it is false here, and a later coverage run
never kills an executing one. Coverage runs still collapse among THEMSELVES
-- one running plus one pending -- so a clock that ticks faster than the
fleet drains cannot pile them up.

---------------------------------------------------------------------------
DECISION 2026-09-06: `cancel-in-progress` ON PUSHES TO MAINLINE STAYS FALSE.
---------------------------------------------------------------------------

This was re-examined deliberately, as part of giving every job in this file
an explicit `timeout-minutes` (see the note above `jobs:`). The question was
whether a newer mainline commit should displace a RUNNING mainline run
instead of queueing behind it. The answer is no, for three reasons, the first
of which is not written down anywhere else and is the decisive one.

1. THE PUBLISH TAIL IS AT THE END OF THE RUN, SO CANCELLATION LANDS ON IT.
   Trace the `needs:` graph: `push-tag` waits on all four build jobs, which
   wait on all four lints; `create-release` waits on `push-tag`;
   the cache push (`push-to-attic`, since 2026-11-16 its own workflow,
   `cache-push.yml`, outside this graph) waited on the whole test and
   lib-check tier. Every job that
   PUBLISHES anything is therefore the last thing a run does. With
   `cancel-in-progress: true`, a push that arrives while a run is in its
   final tier kills precisely the jobs that were about to ship, and ships
   nothing; the replacement run then reaches the same tier and is killed by
   the next push. On a branch that several agents land on continuously, the
   steady state is that NOTHING EVER SHIPS. This is not hypothetical -- it
   cost this project a twelve-hour publish delay. `false` is what makes a
   run that reached the publish tier able to finish reaching it.

2. `false` COSTS NOTHING IN DRAINAGE, BECAUSE THE PENDING SLOT IS ALREADY
   COLLAPSED. GitHub allows exactly ONE pending run per group whatever this
   setting says. A burst of twenty pushes to `dev` therefore leaves one
   running plus one pending under `false`, and one running plus one pending
   under `true` as well -- `true` differs only in ALSO killing the one that
   started. The saving `true` would buy is not queue depth; it is only the
   remaining runtime of a run already underway.

3. THAT REMAINING RUNTIME IS NOW BOUNDED, WHICH IT WAS NOT WHEN THIS BLOCK
   WAS LAST TOUCHED. Thirty of this file's forty-two jobs carried no
   `timeout-minutes` and inherited GitHub's 360-minute default, so "queued
   behind a started run" had a six-hour worst case per job and no computable
   ceiling for the run. All forty-two are now bounded, and the longest path
   through `needs:` that a PUSH can take is
     test-ui-tests (150) -> push-to-attic (60) = 210 minutes
   (now test-ui-tests alone: the cache push left this file).
   A started mainline run can hold its group for at most three and a half
   hours of EXECUTION, and the argument for `false` no longer has to appeal
   to an unbounded quantity.

   The honest caveat: `timeout-minutes` bounds execution, not QUEUEING. A job
   waiting for a self-hosted runner has not started its clock, so on a starved
   fleet a run can still sit open far longer than 210 minutes. What is now
   bounded is the thing that actually costs the fleet -- a job HOLDING a
   runner and not letting go. A job waiting for one strands nothing.

Against all this, the case FOR `true` on push is that a superseded mainline
run produces a verdict on a commit that is no longer the tip. That is a real
cost, and it is the reason this block groups mainline pushes at all rather
than giving each commit its own group. It is paid for separately, by the
periodic coverage run described above, which puts a real verdict on `dev`'s
tip on a clock. Cancellation is not needed to buy it, and reason 1 says
cancellation would cost more than it buys.

WHAT WOULD CHANGE THIS. If the publish tail were moved out of this workflow
into a separate workflow keyed on a successful run of this one, reason 1
would stop applying and `true` would become arguable. Until then, do not
flip line 182 to a constant.

## The codetracer workflow: sibling refs and the Windows bootstrap

Moved from the comment above `windows-bootstrap-smoke` in `.github/workflows/codetracer.yml`.
GitHub refuses a workflow file over 512,000 bytes: every run, pushed or dispatched, ends as a
startup failure with no jobs and "This run likely failed because of a workflow file issue".
The file crossed it at 10deaa18de6 (512,978 bytes); its parent, at 511,737, still started.
Long explanations belong here, with a pointer in the workflow.

```text
WHY EVERY `siblings:` ENTRY CARRIES AN EXPLICIT `=dev` REF.

`metacraft-github-actions/setup-dev-env` clones cross-repo siblings via its
`clone-siblings` sub-action. A bare entry (`codetracer-trace-format`) asks
that action to resolve the revision from a *workspace lock*. An entry of the
form `name=ref` skips that lookup and clones `ref` directly.

WHICH lock answers a bare entry changed on 2026-09-30. Since
reprobuild-specs Unified-Locking-And-Hooks.md §14.5 it is the triggering
commit's own committed `repro.lock` (`lock-store: committed`, the default;
no manifests repo is contacted). The history below is about the lock it
read BEFORE that: a per-commit record published to
`metacraft-labs/metacraft-manifests@latest` by the workspace tooling's
pre-push hook.

Record publication for this repo stopped on 2026-08-02 (last entry:
`locks/dev/codetracer/784c9bda…​.xml`). `clone-siblings` probed the pushed
commit and its parent only (`--no-walk`), so `dev` stayed resolvable for
exactly one more commit and then broke: 8d587343 (parent 784c9bda) was the
last green `Setup dev env`; 3583cd6b (run 30951549711, 2026-08-04) was the
first red one, and every push after it failed the same way:

  ##[error]No workspace lock for codetracer (candidates: <sha> <parent>).
  Neither a repo-workspaces locks/<project>/codetracer/<sha>.xml nor a
  reprobuild locks/<project>/codetracer/<sha>.toml exists in
  metacraft-labs/metacraft-manifests@latest.

That took out `lint-rust`, `test-non-gui`, `test-ui-tests` (both legs),
`test-ui-tests-rr`, `visual-replay-regression-gate` and `ct-test-providers`
in their first real step, which in turn left nine jobs declaring `needs:` on
them `skipped` — the exact "the tests never ran" state `ci-verdict` exists
to name.

The fix at the time was to stop depending on that record: siblings were
pinned to the branch the lock itself recorded for every one of them
(`upstream="dev"` in 784c9bda's lock), which is also what the lock-free
paths in this file already do — the `clone-repo` steps in
`viewmodel-tests` / `test-non-gui` all clone `ref: dev`.

ONE FAMILY OF SIBLINGS NO LONGER PARTICIPATES IN ANY OF THIS. codetracer's
from-source dependencies — isonim and the four nim-* libraries — are
provisioned by `.github/actions/provision-repro-lock-siblings` from the
`repro.lock` COMMITTED IN THIS REPO, at exact SHAs, with no manifest repo
in the path at all. A lock that lives next to the source it describes
cannot lapse, and does not have to be told which repos a developer happened
to have checked out. Since §14 that is also the lock a bare entry resolves
from.

This changes WHERE a revision comes from, not WHICH repos are provisioned
or what any job asserts. Dropping an `=dev` suffix now restores per-commit
pinning for that sibling once this repo's committed `repro.lock` pins it
(`clone-siblings` refuses a bare entry the lock does not pin, and the
`workspace-lock-freshness` job checks every bare-declared sibling against
that lock). `ci/test/sibling-provisioning-test.sh` treats a bare entry as
the good shape and holds the remaining branch-tip entries under a
shrink-only ceiling (`BRANCH_TIP_CEILING`); lower it when one is converted.

NOTE (CIP-5 Wave 4): the whole Windows platform was migrated as a single
unit (honoring the prior "move the whole platform or none of it" rule) from
the GitHub-hosted `windows-latest` onto the self-hosted `eph-win-x64`
class, now that it is provisioned. These jobs keep their DIY env.ps1
(`windows-diy`) toolchain path unchanged — only the runner label moved;
`eph-win-x64` is the DIY-Windows runner. `eph-win-arm64` is intentionally NOT
added here (env.ps1 ARM support is unverified in CI and that class still
queues); revisit once eph-win-arm64 is live.

WHY EVERY eph-win-x64 JOB STARTS WITH "Ensure Git and Git Bash":
the migration above moved the runner label but inherited the GitHub-hosted
`windows-latest` *image contract*, and `eph-win-x64` does not honour it.
The garm-provisioned image ships neither `git` nor `bash` on PATH, which
took out three of the four Windows jobs in three different places:

  windows-bootstrap-smoke   "Validate env.sh syntax"   -> bash: command not found
  windows-named-pipe-tests  "Install Rust toolchain"   -> bash: command not found
                            (dtolnay/rust-toolchain's own step is shell: bash)
  windows-rust-components   "Checkout"                 -> Input 'submodules' not
                            supported when falling back to the GitHub REST API

All three logs also carry actions/checkout's tell: "The repository will be
downloaded using the GitHub REST API / To create a local Git repository
instead, add Git 2.18 or higher to the PATH." Runs 30726348404, 31180327493
and 31385899773 fail identically, so this is the steady state of the lane,
not a one-off.

`ci/ensure-git-for-checkout.ps1` already solved exactly this — it finds or
provisions a pinned, digest-verified PortableGit and puts BOTH `cmd/`
(git.exe) and `bin/` (bash.exe) on GITHUB_PATH. It was wired into
`origin-dap-windows` only, where its step is the one Windows step that has
been passing throughout. Every eph-win-x64 job now runs it, first, before
checkout: the jobs that check out submodules need git *for* the checkout,
and the jobs whose first real step is `shell: bash` need bash before it.
It is fetched over HTTPS at the immutable `github.sha` rather than run from
the tree because at that point there is no tree — the checkout is the step
it is making possible.

`ci/test/windows-runner-bootstrap-test.sh` pins this: it fails if any
eph-win-x64 job stops opening with the bootstrap.
```

## The codetracer workflow: how each timeout-minutes was arrived at

Moved from the head of `.github/workflows/codetracer.yml` for the same 512,000-byte limit.

```text
EVERY JOB BELOW CARRIES AN EXPLICIT `timeout-minutes`, AND HOW EACH ONE WAS
ARRIVED AT.

Before 2026-09-06 twelve of this file's forty-two jobs were bounded and
THIRTY were not. An unbounded job inherits GitHub's 360-minute default, which
on `ubuntu-latest` costs a slow queue and on a self-hosted runner costs the
runner: the org GARM pool was measured at fourteen runners total, twelve busy,
two offline. Twenty-five of the thirty unbounded jobs ran on self-hosted
runners -- including every build-artefact job and all four lint lanes -- so a
hung job did not idle, it stranded a scarce machine for six hours.

THE RULE THE NUMBERS FOLLOW. Each bound is derived from that job's OWN
measured green duration over a 200-run window (2026-09-03 to 2026-09-05,
2356 job records), and the measurement is quoted in a comment on the job. No
single number is copied across jobs: a uniform bound is a guess wearing a
measurement's clothes, and the next reader cannot tell which bounds were
reasoned about. Where a job's greens are tightly clustered the bound is a
multiple of the MAX green, not the median -- for `dmg-build` the max green is
3.7x the median, and that spread is a cold Nix cache, which is a normal green,
not an anomaly. 15 minutes is used as a floor for jobs whose whole body is
seconds of work, because below that the bound would be measuring runner setup.

ERRING GENEROUS, DELIBERATELY. A timeout that fires on healthy work is worse
than no timeout: it converts a slow green into a red and teaches people to
ignore reds. Every bound here is at least ~2x the slowest green ever observed
for that job and most are 3-5x. The intent is to catch a HUNG job, not a slow
one.

THE TWO TRAPS IN READING `gh run view --json jobs`, both of which caught an
earlier pass at this and both of which are why several bounds below are much
wider than a naive reading would give:

  * A `cancelled` duration is NOT a duration. It says only that the job was
    still running at that instant, which is a LOWER bound. In this window
    every reading over 60 minutes was a cancellation, and the largest of them
    came in pairs -- `test-ui-tests-rr` and `test-ui-tests (nixos)` both stop
    at exactly 128.7m in run 33732534675 -- which is the signature of a whole
    run being cancelled, not of two jobs finishing.

  * A `failure` duration is not a green duration either, and usually is not
    even close. These jobs fail EARLY and skip the rest: `viewmodel-tests`
    stops at step 15 of 31, `cross-process-linux` at step 7 of 9,
    `ct-test-providers` at step 6 of 11. The green path runs everything they
    skipped, so a failure duration is a lower bound on green. Failure
    durations are used below only to check that a bound clears them by a wide
    margin, never as the duration itself.

TEN JOBS HAVE NO GREEN SAMPLE AT ALL in this window, which is a finding in its
own right and is recorded on each of them rather than papered over:
`origin-dap-macos-nightly`, `cross-process-linux`, `viewmodel-tests`,
`dmg-lib-check`, `test-non-gui` (both legs), `test-ui-tests` (both legs),
`ct-test-providers`, `push-to-attic`, `create-release`, `ci-verdict`. Of
these, `push-to-attic` and `create-release` have no sample of ANY kind -- only
zero-length cancellations, meaning they never started. (`push-to-attic` has
since moved to its own workflow, cache-push.yml, 2026-11-16.) Their bounds are
structural, not measured, and say so. Nine of the twelve ALREADY-bounded jobs
have no green sample either; the whole Windows family is red.

AN EXISTING BOUND THIS MEASUREMENT CALLS INTO QUESTION. `test-ui-tests-rr`
carries `timeout-minutes: 120`, but that job was observed still EXECUTING at
128.7m (run 33732534675) and at 120.3m (run 33733277454) before its run was
cancelled. Those are lower bounds, so it is not proven that a healthy
`test-ui-tests-rr` exceeds 120m -- but it is not proven that it does not, and
120 is below a length this job has demonstrably reached. The new bound on its
sibling `test-ui-tests` is set to 150 for exactly this reason. `-rr`'s 120 is
left as-is here rather than changed on lower-bound evidence alone; the first
time it times out at 120 with the suite still progressing, raise it to 150 to
match.

THIS IS NOT WHAT `queue-watchdog` DOES, DESPITE THE NAME. Read that job before
assuming otherwise -- an earlier attempt to reason about it went wrong exactly
here. `queue-watchdog` runs only on `pull_request` and asks a WITHIN-RUN
question: is anything servicing THIS run, or are all its jobs `queued` with
none `in_progress`? It watches for a runner-provisioning outage, not for a job
that holds a runner and will not give it back. It never looks at another run
and never looks at a concurrency group, so it cannot see the condition these
bounds address. Its own 300-minute bound is likewise not a duration: it polls
until the run is fully scheduled, which is why its greens run 77-122 minutes.

The bounds above are the structural answer to "how long can one run hold this
group", and they answer it WITHOUT a watchdog. With every job bounded and
`ci/verdict/job-timeouts.py` keeping them bounded, the worst case is the
longest path through `needs:`, computable from this file alone. For a push
that is test-ui-tests (150) -> push-to-attic (60) = 210 minutes. (Since
2026-11-16 the cache push is cache-push.yml, outside this graph, so the
longest path is now test-ui-tests alone.) A watchdog
would report the same fact later, and only after a runner had already been
stranded for the afternoon.
```

`test-ui-tests` has been bounded at 210 minutes since the Firefox scenario lane joined it.
