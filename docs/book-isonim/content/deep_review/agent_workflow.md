---
title: The agent workflow
order: 3
---

# The agent workflow

An agent produces a review the way a person does: it runs `ct review collect`,
then points CodeTracer at what it produced. There is no agent-specific
collection path.

```sh
ct review collect --repo . --diff main..HEAD --recordings .ct/runs -o .ct/review
ct agent evidence .ct/review
```

`ct agent evidence` takes the dataset and nothing else in the common case. The
session, task and workspace are read from the environment the agent already runs
under — `CODETRACER_AGENT_SESSION_ID`, `CODETRACER_AGENT_TASK_ID`,
`CODETRACER_AGENT_WORKSPACE` — because the harness that launched the agent knows
all three, and asking the agent to restate them only invites disagreement.
`--session`, `--task` and `--workspace` override the environment for use outside
a managed session and in tests.

When none of the three sources names a session, the command **fails and says
so**. It does not invent an id, because an invented one attaches the review to
the wrong conversation and nothing downstream can tell:

```console
$ ct agent evidence .ct/review
error: `ct agent evidence` could not tell which agent session this evidence belongs to.
  It reads the session from CODETRACER_AGENT_SESSION_ID, which the agent harness sets;
  that variable is unset, no --session was given, and the dataset at '.ct/review/review.json'
  carries no session reference of its own.
  Export CODETRACER_AGENT_SESSION_ID, or pass --session <ID> explicitly.
```

`ct agent evidence` accepts either the directory `ct review collect` produced or
the `review.json` inside it. (The text `ct agent prompt` prints spells the
collection `-o review.json`; `--output` always names a *directory*, so that form
produces a directory called `review.json` — which both `ct agent evidence` and
`ct review` open, because they resolve a directory to the dataset inside it.)

## Telling the agent to do it

CodeTracer ships the prompt text. Print it with:

```sh
ct agent prompt
```

and install it into a project's agent instructions with:

```sh
ct agent prompt >> AGENTS.md
```

The text teaches the pair of commands above, tells the agent to fix a failing
suite rather than hand over evidence for it, permits collecting from a dirty
working tree provided it says so, and forbids hand-writing a dataset — a file an
agent assembled itself asserts coverage and execution that never happened.

## The end-of-turn hook

A project that would rather not depend on the agent remembering can run the
collection from an end-of-turn hook. `ct agent end-of-turn` runs the *same two
commands, in that order*, and prints each one as it runs it:

```console
$ ct agent end-of-turn
+ ct review collect --repo /home/you/scale_sum --diff HEAD~..HEAD --recordings .ct/runs --output .ct/review
DeepReview collect complete: 2 recordings collected, 1 files, 1 with coverage, 2 function executions
Review dataset ready: .ct/review/review.json
Associated with agent session: rv8-demo-session (acp)
Open it with: ct review .ct/review
+ ct agent evidence .ct/review
{"sessionId":"rv8-demo-session","taskId":"rv8-demo-task", …}
```

It takes all of `ct review collect`'s options, and reads them from the
environment when they are not given, so the hook line in a harness's
configuration can be bare:

| Variable                       | Fills in            | Default    |
| ------------------------------ | ------------------- | ---------- |
| `CODETRACER_REVIEW_REPO`       | `--repo`            | the workspace |
| `CODETRACER_REVIEW_DIFF`       | `--diff`            | —          |
| `CODETRACER_REVIEW_DIFF_FILE`  | `--diff-file`       | —          |
| `CODETRACER_REVIEW_RECORDINGS` | `--recordings`      | `.ct/runs` |
| `CODETRACER_REVIEW_OUTPUT`     | `--output`          | `.ct/review` |

The two are not exclusive, and the trade is real: prompting keeps the judgement
of *what is worth reviewing* with the agent, which is where it belongs; a hook is
reliable but indiscriminate and will produce datasets for turns nobody wanted
reviewed. A project that uses a hook should still prompt, so the agent knows what
the hook will do and does not duplicate it.

## Reading the result

The session a review is collected under is what the Agent Activity panel shows
when the review is opened — see
[The Agent Activity panel](/deep_review/reading). The session is stored **by
reference**, so the dataset carries an id rather than a transcript.

## See also

- [Collecting a review](/deep_review/collecting) — the commands, in the
  non-agent case.
- [`ct` CLI reference](/reference/ct_cli) — the full `ct agent` flag tables.
- [Not yet available](/deep_review/not_yet_available) — the deferrals, named.
