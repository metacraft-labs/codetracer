
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
   `push-to-attic` waits on the whole test and lib-check tier. Every job that
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
     test-ui-tests (150) -> push-to-attic (60) = 210 minutes.
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
